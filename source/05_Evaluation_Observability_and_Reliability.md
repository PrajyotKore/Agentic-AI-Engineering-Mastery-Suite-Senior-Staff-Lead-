[TOC]

# Part 1: Why Agent Evaluation Is Hard

Evaluating a single LLM completion is already difficult: outputs are open-ended, many answers are equally correct, and quality is partly subjective. Evaluating an *agent* is harder by at least an order of magnitude, because an agent is a stochastic program that makes a sequence of decisions, calls external tools with side effects, reads an environment that changes, and may take dozens or hundreds of steps before producing an outcome. This part builds the mental model you need before choosing any metric or tool.

## The Agent as a Stochastic Policy Over an Environment

The cleanest first-principles framing is reinforcement-learning vocabulary. An agent is a policy `pi(action | history)` implemented by an LLM plus scaffolding (system prompt, tool schemas, memory, planner). It interacts with an environment `E` (APIs, filesystem, browser, a user) that returns observations. A run produces a **trajectory**:

```
tau = (s0, a1, o1, a2, o2, ..., aT, oT, final_answer)
      s0 = initial state + task
      a_i = model action (tool call, message, or final answer)
      o_i = observation (tool result, user reply, error)
```

Evaluation asks questions about the *distribution* of trajectories, not a single one:

- **Outcome**: Did the final state of the environment satisfy the goal? (Was the refund issued? Do the tests pass?)
- **Process**: Was the path acceptable? (No policy violations, no unnecessary destructive calls, reasonable cost.)
- **Consistency**: How often does it succeed if we run it again on the same task?
- **Efficiency**: Steps, tokens, wall-clock, dollars.
- **Safety**: Did it ever do something it must never do, even once?

Because the policy is sampled (temperature, nondeterministic batching on inference servers, tool-result variance), every one of these is a random variable. A single run tells you almost nothing.

## Sources of Difficulty

| Difficulty | Why it hurts | Typical mitigation |
|---|---|---|
| Non-determinism | Same input yields different trajectories even at temperature 0 (batch-dependent kernels, MoE routing, provider-side changes) | Repeat trials, report distributions and confidence intervals |
| Many valid paths | Exact trajectory matching penalizes correct alternatives | Evaluate end state; use partial-order or milestone checks for process |
| Long horizons | Errors compound; credit assignment is unclear | Step-level and milestone grading; trace inspection |
| Side effects | Can't re-run against production; real APIs mutate state | Sandboxed, resettable environments; mocks with recorded fixtures |
| Open-ended outputs | No string-equality oracle | Programmatic checkers where possible, calibrated LLM judges elsewhere |
| Environment drift | Websites, APIs, and data change over time, breaking benchmarks | Pin environment snapshots; containerize; version fixtures |
| Cost | Each eval run may cost dollars and minutes | Tiered suites; caching; sampling; smaller smoke sets in CI |
| Human-in-the-loop tasks | Real users respond unpredictably | User simulators with personas, validated against real transcripts |
| Moving model targets | Providers update model snapshots | Pin model versions; re-baseline on every upgrade |

## Compounding Error: The Core Arithmetic

If each step of an agent independently succeeds with probability `p`, a task requiring `n` correct steps succeeds with roughly `p^n`. At `p = 0.98` and `n = 30`, success is about 0.55. At `p = 0.95`, it is 0.21. This is why a model that scores 95% on single tool-call benchmarks can still be useless on 30-step workflows, and why small per-step improvements produce dramatic end-to-end gains. Real agents are not independent per step (they can recover from errors, which raises success; or errors can cascade, which lowers it), but the arithmetic explains why **recovery behavior** is a first-class thing to evaluate.

> [!TIP]
> When a stakeholder asks "why is the agent only 60% on end-to-end when the model is 97% on function calling?", show the `p^n` curve. Then pivot to the two levers that actually matter: reduce `n` (better tools that do more per call, deterministic workflow code for the known parts) and increase recovery (validation, self-check, retries on tool errors). Staff engineers win this argument by changing the architecture, not by asking for a better model.

## The Evaluation-Driven Development Loop

Mature teams treat evals as the specification of the agent. The loop:

```
   +-------------------+       +------------------+
   | Production traces | ----> | Triage & label   |
   +-------------------+       | failures         |
            ^                  +--------+---------+
            |                           |
            |                           v
   +--------+---------+       +------------------+
   | Deploy (canary,  |       | Add to golden /  |
   | shadow, A/B)     |       | regression set   |
   +--------+---------+       +--------+---------+
            ^                           |
            |                           v
   +--------+---------+       +------------------+
   | CI eval gates    | <---- | Change prompt,   |
   | (offline)        |       | tools, model     |
   +------------------+       +------------------+
```

Every production incident should become a test case. Every change should be judged against the suite. The suite, not anyone's intuition from five hand-tried examples, decides what ships.

> [!WARNING]
> "Vibe checking" a prompt change on a handful of examples is the most common source of agent regressions. A change that fixes the three cases you looked at frequently breaks 8% of cases you didn't. Without a suite of at least a few hundred representative tasks run with multiple trials, you cannot distinguish a real improvement from noise.

# Part 2: The Evaluation Taxonomy

There is no single "agent accuracy" number. You need a layered taxonomy, analogous to the test pyramid in classical software: many cheap, fast, narrow tests at the bottom and fewer expensive, realistic tests at the top.

```
                 /\
                /  \     Online: A/B, user feedback, business KPIs
               /----\
              /      \   End-to-end outcome (sandboxed environment, full task)
             /--------\
            /          \  Trajectory / process evals (step order, policy)
           /------------\
          /              \ Tool-call accuracy (selection + arguments)
         /----------------\
        /                  \ Component evals (retriever, router, extractor, prompt units)
       /--------------------\
```

## Component Evals

Components are the deterministic-ish building blocks: a retriever, a query rewriter, an intent classifier/router, a structured extractor, a summarizer, a guardrail classifier. These can be evaluated with classical ML metrics.

| Component | Metrics | Oracle |
|---|---|---|
| Retriever | Recall@k, MRR, nDCG | Labelled relevant document IDs |
| Router / intent classifier | Accuracy, per-class precision/recall, confusion matrix | Labelled intents |
| Structured extractor | Field-level exact match, F1, schema validity rate | Gold JSON |
| Summarizer | Faithfulness (claims supported by source), coverage | LLM judge with source; human spot checks |
| Guardrail classifier | False positive rate, false negative rate at operating threshold | Labelled safe/unsafe set |
| Planner | Plan validity, coverage of required subgoals | Milestone list per task |

Component evals are cheap and pinpoint regressions, but they do not guarantee the agent works: a perfect retriever is useless if the agent never calls it.

## Tool-Call Accuracy

For a given state, did the agent pick the right tool and fill the arguments correctly? This decomposes into:

- **Tool selection accuracy**: correct tool name (including choosing *no* tool when appropriate, i.e. relevance detection).
- **Argument accuracy**: each argument matches by type and value; normalized comparisons for dates, enums, numbers.
- **Schema validity**: the call parses and validates against the JSON Schema.
- **Parallel/multiple calls**: the set of calls matches (order-insensitive when calls are independent).
- **Abstention**: refusing or asking a clarifying question when required information is missing, instead of hallucinating arguments.

The Berkeley Function Calling Leaderboard (BFCL) popularized AST-based matching: parse the call into an abstract syntax tree and compare function name and each argument against a set of acceptable values, rather than doing string equality.

```python
from dataclasses import dataclass
from typing import Any, Callable

@dataclass
class ExpectedCall:
    name: str
    # each arg maps to a list of acceptable values or a predicate
    args: dict[str, list[Any] | Callable[[Any], bool]]
    optional: set[str] = frozenset()

def match_call(actual: dict, expected: ExpectedCall) -> tuple[bool, str]:
    if actual.get("name") != expected.name:
        return False, f"wrong tool: {actual.get('name')} != {expected.name}"
    a_args = actual.get("arguments", {})
    for k, acceptable in expected.args.items():
        if k not in a_args:
            if k in expected.optional:
                continue
            return False, f"missing arg {k}"
        v = a_args[k]
        ok = acceptable(v) if callable(acceptable) else v in acceptable
        if not ok:
            return False, f"bad value for {k}: {v!r}"
    extra = set(a_args) - set(expected.args)
    if extra:
        return False, f"unexpected args {sorted(extra)}"
    return True, "ok"

# usage
exp = ExpectedCall(
    name="search_flights",
    args={
        "origin": ["SFO"],
        "destination": ["JFK", "EWR", "LGA"],   # any NYC airport acceptable
        "date": lambda d: d == "2026-12-03",
    },
)
```

> [!WARNING]
> Single-step tool-call evals are usually run by replaying a fixed conversation prefix and checking the *next* call. This hides compounding effects and also hides cases where the model would have taken a different (valid) path earlier. Use them as unit tests for tool schemas and descriptions, not as a proxy for task success.

## Trajectory (Process) Evals

Trajectory evals grade the *path*. Typical checks:

- **Required milestones**: certain calls must occur (e.g. `verify_identity` before `issue_refund`).
- **Ordering constraints**: partial orders, not total orders. Express as a DAG of required precedences.
- **Forbidden actions**: never call `delete_account`; never send email to external domains.
- **Efficiency**: step count, redundant calls (same tool, same args), backtracking.
- **Policy adherence**: graded by an LLM judge against a written policy (tau-bench style).
- **Reasoning quality** (optional and expensive): did the stated plan match actions?

Matching strategies, from strict to lenient:

| Strategy | Description | Use when |
|---|---|---|
| Exact match | Trajectory equals reference sequence | Deterministic workflows only |
| In-order subsequence | Reference calls appear in order; extras allowed | Required ordering with tolerance for exploration |
| Any-order set match | Reference calls all appear; order ignored | Independent sub-tasks |
| Precedence DAG | Specific pairs must be ordered | Real business policies (auth before action) |
| Milestone + judge | Programmatic milestones plus LLM-judged quality | Open-ended research and coding agents |

```python
def check_precedence(trace_calls: list[str], must_precede: list[tuple[str, str]]) -> list[str]:
    """Return violations where B happened without A happening earlier."""
    violations = []
    first_seen = {}
    for i, name in enumerate(trace_calls):
        first_seen.setdefault(name, i)
    for a, b in must_precede:
        if b in first_seen and (a not in first_seen or first_seen[a] > first_seen[b]):
            violations.append(f"{b} executed before {a}")
    return violations

check_precedence(
    ["lookup_order", "issue_refund", "verify_identity"],
    [("verify_identity", "issue_refund")],
)  # -> ['issue_refund executed before verify_identity']
```

> [!TIP]
> Grade outcomes first, process second. Anthropic's and OpenAI's public guidance on agent evals both converge on this: agents frequently discover valid paths the eval author didn't anticipate, and over-specified trajectory checks punish creativity and become brittle. Reserve strict process checks for things that are *policy* (security, compliance, irreversible actions), and leave the rest to outcome and efficiency metrics.

## End-to-End Outcome Evals

The gold standard: put the agent in a realistic, resettable environment, give it the task, let it run to completion, and then check the **final environment state** with a programmatic verifier.

- Coding agent: run the hidden test suite (SWE-bench style: FAIL_TO_PASS tests must now pass, PASS_TO_PASS tests must still pass).
- Customer-service agent: compare the final database state to the expected state (tau-bench style), plus check required information was conveyed to the user.
- Browser/computer-use agent: check DOM/application state or files on disk (WebArena, OSWorld evaluator scripts).
- Research agent: compare final answer to a gold answer with normalization (GAIA quasi-exact match), or judge against a rubric.

Architecture of an outcome harness:

```
+-----------+     task      +------------------+   tool calls   +------------------+
| Task      | ------------> | Agent under test | <------------> | Sandboxed env    |
| loader    |               | (pinned model,   |                | (container, DB   |
+-----------+               |  prompt, tools)  |                |  snapshot, mock  |
                            +--------+---------+                |  APIs, browser)  |
                                     | trace                    +--------+---------+
                                     v                                   |
                            +------------------+   final state           |
                            | Trace store      | <-----------------------+
                            +--------+---------+
                                     v
                            +------------------+
                            | Graders: state   |
                            | diff, tests, LLM |
                            | judge, cost      |
                            +--------+---------+
                                     v
                            +------------------+
                            | Results DB +     |
                            | stats + report   |
                            +------------------+
```

```python
# Framework-agnostic pseudocode for an outcome harness
import asyncio, statistics, time

async def run_trial(task, agent_factory, env_factory, graders, seed):
    env = await env_factory(task.env_snapshot)          # fresh, isolated
    agent = agent_factory(seed=seed)
    t0 = time.monotonic()
    try:
        result = await asyncio.wait_for(agent.run(task.prompt, env=env), timeout=task.timeout_s)
        status = "completed"
    except asyncio.TimeoutError:
        result, status = None, "timeout"
    except Exception as e:  # infra errors must be separated from agent failures
        result, status = None, f"error:{type(e).__name__}"
    final_state = await env.snapshot()
    scores = {g.name: await g.grade(task, result, final_state, agent.trace) for g in graders}
    await env.destroy()
    return {
        "task_id": task.id, "seed": seed, "status": status,
        "latency_s": time.monotonic() - t0,
        "tokens": agent.usage.total_tokens, "cost_usd": agent.usage.cost_usd,
        "scores": scores, "trace_id": agent.trace.id,
    }

async def run_suite(tasks, k, **kw):
    sem = asyncio.Semaphore(16)  # respect provider rate limits
    async def guarded(t, s):
        async with sem:
            return await run_trial(t, seed=s, **kw)
    return await asyncio.gather(*(guarded(t, s) for t in tasks for s in range(k)))
```

> [!WARNING]
> Always separate **infrastructure failures** (sandbox crashed, rate-limited, provider 500) from **agent failures**. If you count a 429 as a task failure, your success rate measures your rate limiter. Record `status` distinctly, retry infra errors at the harness level, and report the infra failure rate as its own metric.

## Online vs Offline Evaluation

| Dimension | Offline | Online |
|---|---|---|
| Data | Curated golden and synthetic sets | Real production traffic |
| Ground truth | Known in advance | Usually absent; inferred from feedback, judges, outcomes |
| Speed | Minutes to hours, pre-deploy | Continuous, post-deploy |
| Risk | None to users | Real user impact |
| Coverage | Only what you thought of | The true distribution, including the long tail |
| Methods | Regression suites, benchmarks, red team | Shadow mode, canaries, A/B tests, LLM-judge sampling of live traces, implicit feedback |
| Main failure | Dataset drift from reality | Noisy, delayed, biased signals |

Online signals worth instrumenting:

- **Explicit feedback**: thumbs up/down, ratings, corrections. Sparse and biased toward extremes.
- **Implicit feedback**: task abandonment, user rephrasing the same request, escalation to human, copy/accept rates for generated code, edit distance between agent draft and what the user sent.
- **Outcome signals**: ticket reopened within 7 days, PR merged without revert, refund disputed.
- **Online judges**: run an LLM judge on a sample (e.g. 1-5%) of production traces for policy adherence, hallucination, tone.
- **Guardrail trigger rates**: spikes indicate attacks or regressions.

> [!TIP]
> Shadow mode is the most underused deployment tool for agents. Run the new version on mirrored production inputs with all side-effecting tools stubbed to "dry run", then compare its proposed actions against the live version's actual actions with a pairwise judge. You get real-distribution evaluation with zero user risk. The limitation: you can only shadow the first divergent step faithfully, because after that the observations differ.

# Part 3: Datasets — Golden, Synthetic, and Production-Derived

An eval is only as good as its dataset. The dataset is a model of your production distribution; if it is wrong, every metric downstream is wrong with high confidence.

## Golden Datasets

A golden dataset is a curated, versioned set of tasks with trusted expected outcomes, owned like code.

A good golden example record:

```json
{
  "id": "refund-0142",
  "version": 3,
  "split": "regression",
  "tags": ["refund", "multi_item", "policy_edge", "from_incident_INC-2291"],
  "difficulty": "hard",
  "input": {
    "user_persona": "frustrated customer, gives order id only after being asked twice",
    "initial_message": "I want my money back for the broken blender",
    "context": {"user_id": "u_88213"}
  },
  "env_snapshot": "s3://evals/snapshots/retail-db-2026-10-01.sql",
  "expected": {
    "final_state_assertions": [
      "orders['o_5512'].status == 'refunded'",
      "orders['o_5512'].refund_amount == 89.99",
      "orders['o_5513'].status == 'delivered'"
    ],
    "must_precede": [["verify_identity", "issue_refund"]],
    "forbidden_tools": ["delete_order"],
    "must_communicate": ["refund amount", "3-5 business days"]
  },
  "rubric_id": "cs_quality_v2",
  "provenance": {"source": "production_trace", "trace_id": "tr_9f1c", "labeled_by": "ops-team", "reviewed": true}
}
```

Principles:

1. **Stratify by what matters**: intent categories, difficulty, user personas, languages, edge cases, adversarial inputs. Report metrics per stratum, not only the aggregate.
2. **Version everything**: dataset, environment snapshot, graders, rubric. A score is meaningless without the version tuple `(agent_version, dataset_version, grader_version, model_snapshot)`.
3. **Splits**: a *dev* set you iterate on freely, a *held-out test* set you touch rarely (to detect overfitting to dev), and a *regression* set of past failures that must never regress.
4. **Label quality**: double-label a sample and measure inter-annotator agreement. If humans disagree, the task is ambiguous; fix the spec or drop it.
5. **Size**: enough for the confidence interval you need (see Part 5). A few hundred tasks, run with several trials each, is a practical floor for decision-making on a single product surface.

> [!WARNING]
> Goodhart's law hits eval sets hard. If engineers iterate on prompts while watching the dev-set score, the prompt overfits to those examples (often by sneaking example-specific hints into the system prompt). Keep a held-out set that only the CI pipeline sees, and rotate fresh production-derived cases in every month.

## Synthetic Data Generation

Synthetic data fills coverage gaps cheaply, but it inherits the biases of the generating model. Use it to *expand* a seed set grounded in reality, never as the sole source.

Common techniques:

- **Persona x scenario x constraint grids**: enumerate dimensions (user type, intent, complication, channel), then have an LLM write the concrete task for each combination. Guarantees coverage of the cross-product.
- **Back-translation from end states**: start from a desired final DB state or a known solution, ask a model to write the user request that would lead there. The verifier comes for free.
- **Perturbation**: take golden tasks and apply transformations (typos, paraphrase, language switch, irrelevant distractors, missing information, contradictory instructions) to test robustness.
- **Adversarial generation**: a red-team model searches for inputs that break the agent (Part 9).
- **Environment-first generation**: for coding agents, mine real repositories for commits with tests (SWE-bench and SWE-Gym style pipelines); for tool agents, generate tasks by sampling valid tool-call chains and verbalizing them.

```python
# Pseudocode: grid-based synthetic task generation with a verifier built in
import itertools, json

PERSONAS = ["new customer", "power user", "non-native English speaker", "angry customer"]
INTENTS = ["refund", "exchange", "address change", "order status"]
COMPLICATIONS = ["none", "missing order id", "order outside return window", "two orders match"]

GEN_PROMPT = """You write realistic customer-service test cases.
Persona: {persona}
Intent: {intent}
Complication: {complication}
Database excerpt: {db_excerpt}
Return JSON with: initial_message, hidden_user_facts (things the user knows but only
reveals when asked), expected_final_state_assertions (python expressions over the db),
and correct_policy_behavior (one sentence)."""

def generate(llm, db_excerpt):
    for p, i, c in itertools.product(PERSONAS, INTENTS, COMPLICATIONS):
        raw = llm.complete(GEN_PROMPT.format(persona=p, intent=i, complication=c,
                                             db_excerpt=db_excerpt), response_format="json")
        case = json.loads(raw)
        case["tags"] = [p, i, c, "synthetic"]
        yield case

# Then: execute expected assertions against a reference solution to validate the case,
# dedupe by embedding similarity, and send a sample to human review before admitting.
```

> [!WARNING]
> Synthetic tasks generated by model family X are systematically easier for model family X (shared phrasing, shared assumptions about what is "reasonable"). If you compare vendors on a synthetic set generated by one vendor's model, you have a biased benchmark. Use mixed generators and validate a sample against human-written tasks.

## Production-Derived Datasets

The highest-value source of eval cases is production traces, especially failures.

Mining pipeline:

1. Collect traces with user feedback, escalations, guardrail triggers, errors, unusually long trajectories, or high cost.
2. Cluster them (embed the user request plus failure description, then cluster) to find failure *modes*, not individual failures.
3. For each cluster, pick representative cases, scrub PII, reconstruct environment state, and write the expected outcome.
4. Add to the regression split with a tag linking to the incident or cluster.

> [!IMPORTANT]
> Production traces contain personal data. Before a trace becomes an eval case, run PII detection and redaction, confirm the data-processing basis permits use for testing, and record provenance. Eval datasets frequently end up being shared with vendors or copied to laptops; treat them as production data.

## Dataset Trade-offs

| Source | Realism | Cost | Coverage of edge cases | Ground-truth reliability | Contamination risk |
|---|---|---|---|---|---|
| Hand-written golden | Medium | High | Depends on author imagination | High | Low |
| Production-derived | Highest | Medium (labeling, scrubbing) | Real long tail | Medium-high | Low |
| Synthetic grid | Medium-low | Low | High along chosen dimensions | Medium (needs validation) | Medium |
| Public benchmarks | Low for your product | Free | Generic | Medium (known label errors) | High |

# Part 4: LLM-as-a-Judge

When no programmatic oracle exists, an LLM grades the output. Used well, judges scale human judgment; used naively, they produce confident nonsense that correlates with length and style instead of quality.

## Mechanics

A judge is a prompt plus a model that maps `(input, output, optional reference, rubric) -> score + rationale`. Key design dimensions:

- **Pointwise**: score one output on an absolute scale (binary pass/fail, 1-5 Likert, or rubric checklist).
- **Pairwise**: given outputs A and B, which is better (or tie)? Used for comparing versions.
- **Reference-guided**: judge has access to a gold answer or source documents; turns open-ended grading into comparison, greatly improving reliability.
- **Reference-free**: judge relies on its own knowledge; weakest, use only for style/tone or with strong rubrics.
- **Trajectory judge**: judge sees the whole trace (tool calls and results) and grades process against a policy.

## Rubric Design

Rubrics are the single biggest lever on judge quality.

1. **Prefer binary criteria over Likert scales.** "Did the response state the refund amount? yes/no" is far more reliable than "Rate completeness 1-5." Likert midpoints are poorly calibrated across models and runs.
2. **Decompose** a fuzzy quality into several independent, observable checks; aggregate in code.
3. **Define each criterion operationally** with pass and fail examples.
4. **Ask for reasoning before the verdict** (chain-of-thought improves agreement), but parse only the structured verdict field.
5. **Use structured output** (JSON schema) for verdicts.
6. **One criterion per judge call** when stakes are high; multi-criterion prompts cause criteria to bleed into each other.

```python
JUDGE_PROMPT = """You are grading a customer-support agent transcript against ONE criterion.

Criterion: POLICY_REFUND_WINDOW
Definition: The agent must not issue a refund for an order delivered more than 30 days
before the request date, unless the item is marked defective in the order record.
PASS example: Agent checks delivery date (45 days ago), item not defective, declines and offers store credit.
FAIL example: Agent issues refund for an order delivered 45 days ago with no defect flag.
NOT_APPLICABLE: No refund was requested or discussed.

Order record:
{order_record}

Transcript (including tool calls and results):
{transcript}

First write your reasoning in "reasoning", citing specific turns. Then give "verdict"
as one of PASS, FAIL, NOT_APPLICABLE."""

JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "reasoning": {"type": "string"},
        "verdict": {"type": "string", "enum": ["PASS", "FAIL", "NOT_APPLICABLE"]},
    },
    "required": ["reasoning", "verdict"],
    "additionalProperties": False,
}
```

## Pointwise vs Pairwise

| Aspect | Pointwise | Pairwise |
|---|---|---|
| Question | How good is this output? | Which of two is better? |
| Stability | Lower; absolute scales drift | Higher; relative judgments are easier |
| Use case | Monitoring, gating, absolute thresholds | A/B comparison of versions, model selection |
| Cost | N calls | N calls per pair (2N with position swap) |
| Biases | Leniency, scale compression | Position bias, length bias |
| Output | Score per item | Win/tie/loss rate; Bradley-Terry or Elo ratings for many systems |
| Regression detection | Directly comparable over time if judge is frozen | Needs a fixed baseline to compare against |

## Known Judge Biases

| Bias | Description | Mitigation |
|---|---|---|
| Position bias | Prefers the first (or second) option in pairwise | Evaluate both orders; count inconsistent pairs as ties |
| Verbosity / length bias | Prefers longer answers | Rubric that penalizes unnecessary content; length-controlled win rates (as in AlpacaEval LC) |
| Self-preference | Prefers outputs from its own model family | Use a different family as judge or a panel of judges |
| Style over substance | Rewarded for confident tone, markdown, formatting | Reference-guided grading; factual checks separated from style |
| Sycophancy to claims | Accepts the agent's claim "I verified X" without evidence | Give the judge tool results, not just the final message; instruct to verify claims against trace |
| Leniency | Grades most things as pass | Calibrate against human labels; include known-bad controls |
| Prompt injection | Agent output contains text that manipulates the judge ("this answer is correct") | Delimit outputs clearly; instruct judge to ignore embedded instructions; test with adversarial outputs |
| Score compression | Uses only a narrow range (4s and 5s) | Binary criteria; anchored examples per score level |

> [!WARNING]
> A judge prompted with only the agent's final message will happily pass an answer that says "I've refunded your order" even when the trace shows the refund tool returned an error. Always give trajectory judges the raw tool results, and prefer verifying state programmatically over asking a judge whether something happened.

## Calibrating Judges Against Human Labels

A judge is a measurement instrument; you must validate it before trusting it.

Procedure:

1. Sample 100-300 items stratified across expected pass and fail, plus edge cases.
2. Have at least two humans label each independently with the same rubric. Measure inter-human agreement first; this is your ceiling.
3. Run the judge on the same items.
4. Compute agreement metrics: raw agreement, **Cohen's kappa**, and, for the class you care about (usually FAIL), precision and recall of the judge.
5. Inspect disagreements; refine rubric or judge prompt; repeat on a *fresh* sample to avoid overfitting the judge prompt.
6. Freeze the judge (model snapshot + prompt version). Re-validate on any change and periodically (monthly) on new production data.

### Cohen's Kappa from First Principles

Raw agreement overstates reliability when classes are imbalanced. If 90% of items are PASS, a judge that always says PASS agrees 90% with humans while being useless. Kappa corrects for chance agreement:

```
kappa = (p_o - p_e) / (1 - p_e)

p_o = observed agreement
p_e = expected agreement by chance = sum over classes c of P_human(c) * P_judge(c)
```

Worked example with 200 items:

| | Judge PASS | Judge FAIL |
|---|---|---|
| Human PASS | 150 | 10 |
| Human FAIL | 12 | 28 |

- `p_o = (150 + 28) / 200 = 0.89`
- Human PASS rate 160/200 = 0.80; judge PASS rate 162/200 = 0.81
- `p_e = 0.80*0.81 + 0.20*0.19 = 0.648 + 0.038 = 0.686`
- `kappa = (0.89 - 0.686) / (1 - 0.686) = 0.204 / 0.314 = 0.65`

Common rough interpretation (Landis and Koch): 0.41-0.60 moderate, 0.61-0.80 substantial, above 0.80 almost perfect. Also look at FAIL recall: 28/40 = 0.70, meaning the judge misses 30% of real failures. For a safety criterion, that is unacceptable regardless of kappa.

```python
from sklearn.metrics import cohen_kappa_score, confusion_matrix, classification_report

human = [...]  # list of "PASS"/"FAIL"
judge = [...]
print("kappa:", cohen_kappa_score(human, judge))
print(confusion_matrix(human, judge, labels=["PASS", "FAIL"]))
print(classification_report(human, judge, labels=["FAIL", "PASS"]))
# For ordinal scales (1-5), use weighted kappa:
# cohen_kappa_score(h, j, weights="quadratic")
# For more than two raters, use Fleiss' kappa or Krippendorff's alpha.
```

> [!TIP]
> Report judge-human agreement next to every judge-based metric in dashboards, and compare it against human-human agreement. If humans agree at kappa 0.70 and your judge agrees with humans at 0.68, the judge is about as good as an extra human annotator, which is the right bar. Demanding kappa 0.95 from a judge on a task where humans only reach 0.70 is asking the instrument to be more precise than the definition.

### Correcting Aggregate Metrics for Judge Error

If you know the judge's true positive rate and false positive rate (from calibration), you can correct an observed pass rate. Let `q` be the observed judge-pass rate, `TPR = P(judge PASS | truly PASS)`, `FPR = P(judge PASS | truly FAIL)`. Then the estimated true pass rate is `(q - FPR) / (TPR - FPR)` (the Rogan-Gladen estimator). This matters when comparing two agents whose error profiles may be judged differently, and when reporting absolute rates to leadership.

## Judge Ensembles and Cost

- **Panels**: majority vote of three judges from different families reduces self-preference and variance. Research on "juries" of smaller models has shown they can match a single large judge at lower cost.
- **Cascades**: cheap judge first; escalate uncertain or FAIL verdicts to an expensive judge or a human.
- **Reasoning models as judges**: reasoning models (with extended thinking) are noticeably better at verifying multi-step logic and catching subtle errors in code or math, at higher latency and cost. Use them for hard criteria and offline evals, not for high-volume online sampling.
- **Caching**: judge prompts with a long fixed rubric prefix benefit from provider prompt caching; put the rubric first and the variable transcript last.

> [!TIP]
> Before reaching for any judge, ask: "Can I turn this into a programmatic check?" Many apparent judgment calls are really state checks (did the DB change?), regexes (does the reply contain the tracking number?), or schema checks. Programmatic checks are free, deterministic, and unbiased. A good suite is often 70% code-based graders and 30% judges.

# Part 5: Metrics and Statistics — pass@k, pass^k, and Significance

## pass@k vs pass^k

These two metrics answer opposite questions.

- **pass@k**: probability that *at least one* of k independent attempts succeeds. Measures *capability* with retries or selection (e.g. generate k patches and keep the one passing tests). Introduced for code generation (HumanEval/Codex paper).
- **pass^k** (pass-hat-k): probability that *all* k independent attempts succeed. Measures *reliability/consistency*. Introduced in tau-bench, which showed that even strong models' pass^k drops steeply as k grows on customer-service tasks.

For a task with per-trial success probability `p`: `pass@k = 1 - (1-p)^k` and `pass^k = p^k`. With `p = 0.7`: pass@8 is about 0.9999, pass^8 is about 0.058. The same agent looks nearly perfect or nearly useless depending on which you report.

Unbiased estimators from `n` trials with `c` successes per task (average across tasks):

```python
from math import comb

def pass_at_k(n: int, c: int, k: int) -> float:
    """Unbiased estimator (Chen et al. 2021). Requires n >= k."""
    if n - c < k:
        return 1.0
    return 1.0 - comb(n - c, k) / comb(n, k)

def pass_hat_k(n: int, c: int, k: int) -> float:
    """Unbiased estimator of P(all k succeed) (tau-bench). Requires n >= k."""
    return comb(c, k) / comb(n, k)

# per-task results: list of (n, c)
results = [(8, 8), (8, 6), (8, 1), (8, 0)]
for k in (1, 2, 4, 8):
    pa = sum(pass_at_k(n, c, k) for n, c in results) / len(results)
    ph = sum(pass_hat_k(n, c, k) for n, c in results) / len(results)
    print(k, round(pa, 3), round(ph, 3))
```

| Metric | Answers | Use for | Misleading when |
|---|---|---|---|
| pass@1 (mean success) | Expected success of one attempt | Default headline | Hides variance across tasks |
| pass@k | Can it ever solve it with k tries? | Systems with a verifier choosing among k samples (tests, best-of-n) | No verifier exists in production |
| pass^k | Will it solve it every time? | Customer-facing agents, automation that runs unattended | Reported with too few trials (high variance) |
| Majority@k | Does the consensus answer succeed? | Self-consistency voting systems | Answers aren't comparable for voting |

> [!IMPORTANT]
> Which metric to report is a product decision. A coding assistant with a test-runner verifier and a human reviewer can legitimately be evaluated on pass@k. An agent that processes insurance claims unattended must be evaluated on pass^k, because users experience every run, not the best run.

## Why Statistics Matter So Much for Agents

Agent evals combine two sources of variance: **task sampling** (your dataset is a sample of possible tasks) and **trial sampling** (each task's outcome is random). Small suites plus single trials produce error bars far wider than the differences teams argue about.

For a binary success metric over `N` independent tasks with observed rate `p_hat`, the standard error is `sqrt(p_hat(1-p_hat)/N)`. With `N = 100`, `p_hat = 0.6`: SE is about 0.049, so a 95% interval is roughly plus or minus 9.6 points. A "3-point improvement" on a 100-task suite is noise.

Better intervals for proportions: Wilson score interval (behaves well near 0 and 1). For clustered data (multiple trials per task), use the **cluster bootstrap** or a clustered standard error: resample *tasks*, not trials, since trials of the same task are correlated.

```python
import numpy as np

def cluster_bootstrap_ci(per_task_scores: list[list[float]], iters=10_000, alpha=0.05, seed=0):
    """per_task_scores[i] = list of trial outcomes (0/1) for task i."""
    rng = np.random.default_rng(seed)
    task_means = np.array([np.mean(s) for s in per_task_scores])
    n = len(task_means)
    boots = rng.choice(task_means, size=(iters, n), replace=True).mean(axis=1)
    return task_means.mean(), np.quantile(boots, [alpha/2, 1-alpha/2])

def paired_bootstrap_diff(a: list[float], b: list[float], iters=10_000, seed=0):
    """a[i], b[i] = mean success of system A and B on the SAME task i."""
    rng = np.random.default_rng(seed)
    d = np.array(a) - np.array(b)
    idx = rng.integers(0, len(d), size=(iters, len(d)))
    boots = d[idx].mean(axis=1)
    p_two_sided = 2 * min((boots <= 0).mean(), (boots >= 0).mean())
    return d.mean(), np.quantile(boots, [0.025, 0.975]), p_two_sided
```

## Paired Comparisons

When comparing version A vs B, run both on the **same tasks** and analyze per-task differences. Pairing removes between-task variance (some tasks are just hard), dramatically tightening intervals.

- Binary single trial per task: **McNemar's test** on the discordant pairs (tasks A solved and B didn't, and vice versa).
- Multiple trials per task: paired bootstrap on per-task means, or a mixed-effects logistic regression with a random intercept per task.
- Many comparisons (many criteria, many strata): correct for multiple testing (Holm-Bonferroni) or you will "find" regressions that are noise.

## Power and Sample Size

Before running an expensive eval, decide the **minimum detectable effect** (MDE). For a paired binary comparison, the number of tasks needed scales roughly with `(z_alpha + z_beta)^2 * variance_of_difference / MDE^2`. Rules of thumb for independent proportions near 0.5 at 95% confidence and 80% power: detecting a 10-point difference needs about 400 tasks per arm; a 5-point difference needs about 1,500. Pairing and multiple trials reduce this considerably, which is why you should always pair.

> [!TIP]
> Present eval results to leadership as "B beats A by 4.1 points (95% CI 1.2 to 7.0, paired over 412 tasks x 5 trials)", never as "B: 71%, A: 67%". The interval changes the conversation from opinion to decision, and it prevents the organization from shipping noise. Also publish the per-stratum breakdown: aggregate gains frequently hide regressions in a small but critical category.

> [!WARNING]
> Temperature 0 does not make evals deterministic and does not remove the need for multiple trials. Providers' inference stacks are nondeterministic across batches, and reasoning models often do not allow temperature control at all. Lowering temperature in eval but not in production also means you are measuring a different system than you ship.

## Beyond Success: The Metric Set

A production agent scorecard typically includes:

| Category | Metrics |
|---|---|
| Effectiveness | Task success (pass@1), pass^k, partial credit / milestone completion |
| Safety and policy | Policy violation rate, forbidden-action rate (target zero), PII leakage rate, jailbreak success rate |
| Efficiency | Steps per task, tokens per task (input, cached input, output, reasoning), cost per successful task |
| Latency | Time to first token, time to first action, end-to-end p50/p95/p99 |
| Robustness | Success under perturbation, tool-error recovery rate |
| User experience | Clarifying-question appropriateness, CSAT, escalation rate |
| Infrastructure | Infra failure rate, tool error rate, timeout rate |

> [!TIP]
> "Cost per successful task" is the efficiency metric that matters, not cost per run. A cheaper model that fails twice as often and triggers retries or human escalations is more expensive. Compute it as total spend (including retries and escalation cost) divided by successes.

