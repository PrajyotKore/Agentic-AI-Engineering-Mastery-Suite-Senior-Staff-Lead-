[TOC]

# 1. What Makes a System Agentic

## 1.1 A First-Principles Definition

An **agent** is a system in which a language model *decides the control flow* of a program at runtime: which action to take next, which tool to call, with which arguments, and when to stop. Everything else (memory, tools, planning, reflection) is an elaboration of that one property. A program where the developer hard-codes the sequence of LLM calls is a **workflow**, however sophisticated its prompts are.

This framing comes directly from Anthropic's *Building Effective Agents* (December 2024), which remains the most widely cited taxonomy in industry:

- **Workflows**: LLMs and tools are orchestrated through *predefined code paths*.
- **Agents**: LLMs *dynamically direct their own processes and tool usage*, maintaining control over how they accomplish tasks.

Both are "agentic systems". The distinction matters because it determines how you test, observe, bound cost and reason about failure. A workflow has an enumerable set of execution paths; an agent has an unbounded one.

A useful formalism: treat the agent as a policy `π(a_t | s_t)` where the state `s_t` is the context window (system prompt + history + tool results) and the action `a_t` is either a tool call, a message to the user, or a terminate signal. The environment executes the action and returns an observation `o_t`, and `s_{t+1} = f(s_t, a_t, o_t)`. The function `f` is **context engineering**: what you keep, summarise, drop or retrieve. Most production quality problems live in `f`, not in `π`.

## 1.2 The Autonomy Spectrum

Agency is not binary. Think of it as a ladder where each rung hands one more decision to the model.

| Level | Name | Who decides control flow | Example | Typical failure surface |
|---|---|---|---|---|
| L0 | Single call | Developer | Classify a ticket | Prompt quality |
| L1 | Chain / workflow | Developer | Extract, then translate, then format | Error propagation between steps |
| L2 | Router | Model picks one branch of a fixed set | Route to billing vs tech-support prompt | Misrouting |
| L3 | Tool-using agent | Model picks tools and loops | ReAct support agent with 10 tools | Loops, wrong tool, wrong args |
| L4 | Planning / multi-agent | Model decomposes goals and delegates | Deep research, coding agents | Plan drift, coordination cost explosion |
| L5 | Open-ended autonomous | Model sets its own sub-goals over hours/days | Long-horizon SWE agents, computer use | Safety, irreversibility, unbounded spend |

Two orthogonal axes are often conflated with this ladder:

- **Action reversibility**: read-only search vs. sending email vs. moving money. Autonomy should be *inversely* coupled to irreversibility.
- **Horizon**: number of steps before a human sees output. Error compounds roughly as `p_success ≈ p_step^n`. At 95% per-step reliability, a 20-step task succeeds only ~36% of the time without recovery mechanisms.

> [!TIP]
> Staff-level framing for design reviews: "What is the lowest rung on the autonomy ladder that solves this problem?" Every rung up buys flexibility at the cost of testability, latency and spend. Anthropic's own guidance is to start with the simplest solution and add agency only when it demonstrably improves outcomes on your eval set.

## 1.3 Workflows vs Agents: When to Choose Which

| Criterion | Prefer workflow | Prefer agent |
|---|---|---|
| Task structure | Known, stable decomposition | Unknown number of steps, path depends on findings |
| Input variance | Low | High (open-ended user goals) |
| Latency SLO | Tight (p95 under 2 s) | Relaxed (seconds to minutes) |
| Cost sensitivity | High volume, low margin | High value per task |
| Auditability | Regulated, must explain each step | Outcome-checked rather than path-checked |
| Evaluation | Per-step unit tests | Outcome-based evals plus trajectory analysis |
| Tooling breadth | Few tools, fixed order | Many tools, conditional use |

The pragmatic production pattern in 2026 is **workflow-shaped skeletons with agentic leaves**: a deterministic graph (often LangGraph, Temporal or plain code) where specific nodes are bounded agent loops with their own tool sets, step caps and budgets. This combines the auditability of workflows with local flexibility.

> [!WARNING]
> "Agent-washing" a deterministic process is a common and expensive mistake. If your agent calls the same five tools in the same order 98% of the time (check your traces), you are paying for a model to rediscover a fixed workflow on every request, with added nondeterminism. Compile it into a workflow and keep an agentic fallback for the remaining 2%.

## 1.4 The Building Blocks: The Augmented LLM

Anthropic's taxonomy starts with the **augmented LLM**: a model with access to retrieval, tools and memory. Every pattern in this document composes augmented LLM calls.

```
                +----------------------------------+
   input  --->  |           Augmented LLM          | ---> output
                |  +-----------+   +------------+  |
                |  | Retrieval |   |   Tools    |  |
                |  +-----------+   +------------+  |
                |         +--------------+         |
                |         |    Memory    |         |
                |         +--------------+         |
                +----------------------------------+
```

In 2026 the tool interface is largely standardised by the **Model Context Protocol (MCP)**, which exposes tools, resources and prompts from servers to any compliant client; agent-to-agent delegation across organisational boundaries increasingly uses **A2A** (Agent2Agent, now under the Linux Foundation). Those protocols are covered in a later part of this suite; here the important point is that the *cognitive architecture* (how the model decides) is independent of the *transport* (how tools are reached).

# 2. The Agent Loop

## 2.1 Mechanics

Every tool-using agent, whatever the framework, reduces to this loop:

```
messages = [system, user_goal]
loop:
    response = model(messages, tools)
    if response has tool_calls:
        for call in response.tool_calls:          # possibly in parallel
            result = execute(call)                # sandboxed, timed out, authorised
            messages.append(tool_result(call.id, result))
        messages.append(response)                 # order matters per provider API
    else:
        return response.final_text                # model chose to stop
    enforce_budgets()                             # steps, tokens, wall-clock, $ 
```

The model "stops" by emitting a turn with no tool calls (in Anthropic's Messages API, `stop_reason == "end_turn"` vs `"tool_use"`; in OpenAI's APIs, absence of function calls in the output). Frameworks such as the **OpenAI Agents SDK** (`Runner.run`), **Claude Agent SDK** (the harness behind Claude Code), **Google ADK** (`LlmAgent` executed by a `Runner`), **LangGraph** (`create_react_agent` or a hand-built graph) and **CrewAI/AG2** all wrap exactly this loop, adding tracing, guardrails, handoffs and persistence.

## 2.2 A Minimal, Production-Shaped Implementation

The following uses the Anthropic Python SDK's Messages API, which is stable and well documented. Note the explicit budgets and error-as-observation handling.

```python
import json, time
import anthropic

client = anthropic.Anthropic()

TOOLS = [
    {
        "name": "search_orders",
        "description": "Look up a customer's orders by email. Returns at most 10 orders, newest first.",
        "input_schema": {
            "type": "object",
            "properties": {"email": {"type": "string", "format": "email"}},
            "required": ["email"],
        },
    },
]

def execute(name: str, args: dict) -> str:
    try:
        if name == "search_orders":
            return json.dumps(order_service.search(args["email"]))  # your code
        return json.dumps({"error": f"unknown tool {name}"})
    except Exception as e:  # errors become observations, not crashes
        return json.dumps({"error": type(e).__name__, "detail": str(e)[:500]})

def run_agent(goal: str, max_steps=12, max_seconds=90, max_output_tokens_total=20_000):
    messages = [{"role": "user", "content": goal}]
    started, out_tokens = time.monotonic(), 0
    for step in range(max_steps):
        resp = client.messages.create(
            model="claude-sonnet-4-5",          # pin a specific model version in prod
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )
        out_tokens += resp.usage.output_tokens
        messages.append({"role": "assistant", "content": resp.content})
        if resp.stop_reason != "tool_use":
            return {"status": "done", "steps": step + 1, "answer": resp.content}
        results = []
        for block in resp.content:
            if block.type == "tool_use":
                results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": execute(block.name, block.input),
                })
        messages.append({"role": "user", "content": results})
        if time.monotonic() - started > max_seconds or out_tokens > max_output_tokens_total:
            return {"status": "budget_exceeded", "steps": step + 1, "messages": messages}
    return {"status": "max_steps", "messages": messages}
```

## 2.3 Anatomy of One Iteration: Where Time and Money Go

```
 t0 ----- prefill (input tokens, cache-able) ----- t1 -- decode (output tokens) -- t2 -- tool exec -- t3
          cost ~ input_tokens * p_in                     cost ~ out * p_out             latency of tool
          latency ~ input/prefill_speed (fast)           latency ~ out/decode_speed (slow)
```

Key mechanics:

- **Context grows monotonically** unless you compact. Iteration `k` re-sends all prior turns, so naive total input cost is quadratic in steps: `Σ_k (S + k·Δ) ≈ nS + Δn²/2`.
- **Prompt caching** (Anthropic `cache_control` breakpoints, OpenAI automatic prefix caching, Gemini implicit and explicit context caching) makes the stable prefix cheap: cached reads are typically ~10% of base input price, and also reduce time-to-first-token. Because the agent loop only *appends*, it is the ideal caching workload, provided you never mutate earlier content.
- **Decode dominates latency**; output tokens are 3-5x the price of input and ~100x slower per token than prefill. Verbose reasoning in non-reasoning models (or large thinking budgets in reasoning models) is the main latency lever.

> [!WARNING]
> Inserting a timestamp, a request ID, or a re-ordered tool list near the *top* of the prompt invalidates the cache for everything after it on every call. A single `Current time: 20:24:41` in the system prompt can multiply your input bill by 5-10x on long loops. Put volatile data at the end, in the latest user turn.

## 2.4 Tool Results as the Primary Context Pollutant

In real traces, tool outputs typically account for 60-90% of context tokens. A web page, a log file or a SQL result set is far larger than the model's reasoning. Design tools to return **decision-relevant, bounded** output:

- Paginate and cap (`limit`, `cursor`), and say so in the description.
- Return stable IDs plus summaries; let the model fetch detail on demand.
- Return errors with *actionable* hints ("No orders found for this email. Did you mean to search by order_id? Use get_order(order_id).").
- Strip HTML/boilerplate server-side.

> [!TIP]
> Treat tool design as **agent-computer interface (ACI)** design, a term Anthropic uses deliberately by analogy with HCI. Teams routinely get larger gains from rewriting tool names, descriptions and output shapes than from changing models. Poka-yoke your tools: make wrong usage hard (e.g., require absolute paths, enums instead of free strings).

# 3. Reasoning-and-Acting Architectures

This section covers the canonical cognitive architectures from the research literature, what each actually changes in the loop, and where each earns its keep in production. Many were invented for 2022-2023 models that could not reliably reason without scaffolding; reasoning models have absorbed some of their benefits, and knowing *which* is a staff-level skill.

## 3.1 Chain-of-Thought (Background)

Chain-of-Thought (Wei et al., 2022) showed that eliciting intermediate reasoning tokens improves multi-step problem solving. Mechanically, CoT gives the transformer more serial computation: each generated token is another forward pass that can condition on prior intermediate results. Every architecture below is a way to structure, branch, verify or ground that serial computation.

## 3.2 ReAct (Reason + Act)

**Paper**: Yao et al., 2022, *ReAct: Synergizing Reasoning and Acting in Language Models*.

**Mechanics**: interleave `Thought -> Action -> Observation` steps. The thought lets the model plan and track progress; the action grounds it in external information; the observation corrects hallucination.

```
Thought: I need the user's latest order before I can check the refund policy.
Action: search_orders{"email": "a@b.com"}
Observation: [{"id": "O-9", "date": "2026-11-20", "status": "delivered"}]
Thought: Delivered 5 days ago; policy window is 30 days. Check eligibility.
Action: check_refund_eligibility{"order_id": "O-9"}
Observation: {"eligible": true}
Thought: I can answer now.
Final Answer: ...
```

In 2026, ReAct is not implemented with text parsing of "Action:" lines; native **function calling** replaces the parse step, and the "Thought" is either visible text preceding the tool call, or hidden reasoning in a reasoning model. The *pattern* is the default agent loop of every major SDK.

**Strengths**: simple, adaptive, grounded; each step can react to the last observation.

**Weaknesses**: greedy and myopic (no lookahead); one LLM call per tool call (latency); context accumulates; prone to loops when observations are ambiguous.

> [!WARNING]
> Classic ReAct failure: **repetition loops**. The model calls `search("X")`, gets an unhelpful result, reasons "let me search for X", and calls the same thing again. Mitigate with (1) duplicate-call detection that injects "You already called this with identical arguments; result was ...", (2) step caps, (3) tool outputs that suggest alternatives on empty results.

## 3.3 Plan-and-Execute

**Mechanics**: separate a **planner** (one call producing a multi-step plan) from an **executor** (which carries out each step, often with a cheaper model or a small ReAct loop), plus an optional **replanner** that revises the remaining plan after each step or on failure. Popularised by BabyAGI-style systems and the *Plan-and-Solve* prompting paper (Wang et al., 2023), and by LangGraph's plan-and-execute tutorials.

```
           +---------+   plan[1..n]   +-----------+  result_i  +-----------+
 goal ---> | Planner | -------------> | Executor  | ---------> | Replanner | --+
           +---------+                | (step i)  |            +-----------+   |
                ^                     +-----------+                 |          |
                |___________________ revised plan __________________|   done --+--> answer
```

```python
from pydantic import BaseModel, Field

class Step(BaseModel):
    id: int
    description: str
    tool_hint: str | None = None
    depends_on: list[int] = Field(default_factory=list)

class Plan(BaseModel):
    goal: str
    steps: list[Step]

class ReplanDecision(BaseModel):
    action: str = Field(pattern="^(continue|revise|finish)$")
    revised_steps: list[Step] | None = None
    final_answer: str | None = None

def plan_and_execute(goal, llm_big, llm_small, max_replans=3):
    plan = llm_big.structured(Plan, f"Make a minimal plan for: {goal}")
    done: dict[int, str] = {}
    replans = 0
    while True:
        ready = [s for s in plan.steps if s.id not in done and all(d in done for d in s.depends_on)]
        if not ready:
            break
        step = ready[0]
        done[step.id] = react_loop(llm_small, step.description, context=done, max_steps=6)
        decision = llm_big.structured(ReplanDecision, render(goal, plan, done))
        if decision.action == "finish":
            return decision.final_answer
        if decision.action == "revise":
            replans += 1
            if replans > max_replans:
                break
            plan.steps = [s for s in plan.steps if s.id in done] + decision.revised_steps
    return synthesize(llm_big, goal, done)
```

**Strengths**: explicit global structure; the plan is inspectable (good for human-in-the-loop approval); cheaper models can execute; easier to parallelise independent steps.

**Weaknesses**: plans written before evidence is gathered are often wrong; replanning costs a big-model call per step; rigid plans fail on exploratory tasks.

> [!TIP]
> Show the plan to the user *before* executing irreversible steps. Plan approval is a far better HITL checkpoint than approving each tool call: humans can evaluate intent at plan level, while per-call approval produces rubber-stamping fatigue within minutes.

## 3.4 ReWOO (Reasoning WithOut Observation)

**Paper**: Xu et al., 2023.

**Mechanics**: the planner writes the *entire* plan up front, including tool calls with **variable placeholders** referencing earlier results (`#E1`, `#E2`). A **worker** executes tool calls without any LLM involvement, substituting variables. A **solver** LLM gets the plan plus all evidence and writes the answer. Exactly two LLM calls regardless of number of tools.

```
Plan: Find the CEO of the company that acquired Figma's rival.
#E1 = search["company that acquired <rival>"]
Plan: Extract the company name, then find its CEO.
#E2 = llm_extract["company name from #E1"]
#E3 = search["CEO of #E2"]
Solver: given #E1..#E3, answer.
```

**Strengths**: token-efficient (the paper reported roughly 5x fewer tokens than ReAct on HotpotQA); no observation re-prompting; tool calls can be batched.

**Weaknesses**: brittle when an early result invalidates the plan; no adaptivity mid-execution.

## 3.5 LLM Compiler

**Paper**: Kim et al., 2023, *An LLM Compiler for Parallel Function Calling*.

**Mechanics**: generalises ReWOO into a **DAG** of tool calls. Three components: a **Function Calling Planner** that streams a task DAG with dependencies; a **Task Fetching Unit** that dispatches tasks as soon as their dependencies resolve (like an out-of-order CPU); an **Executor**. A **Joiner** decides whether to answer or replan.

```
planner streams:   1. search("A")   2. search("B")   3. compare($1, $2)   4. join()
scheduler:         [1]---+
                   [2]---+--> [3] --> joiner --> answer | replan
```

Reported results: up to ~3.7x latency speedup and lower cost vs ReAct on parallelisable tasks.

**Today**: native *parallel tool calling* (multiple tool calls in one model turn, supported by OpenAI, Anthropic and Gemini) captures much of the benefit for flat fan-out. LLM Compiler remains valuable when there are *dependent* chains of tool calls that can be planned in advance and executed without round-tripping to the model.

## 3.6 Comparison: ReAct vs Plan-and-Execute vs ReWOO vs LLM Compiler

| Property | ReAct | Plan-and-Execute | ReWOO | LLM Compiler |
|---|---|---|---|---|
| LLM calls per task | One per step | Plan + per-step + replans | 2 | Plan + join (+ replans) |
| Adaptivity to observations | High | Medium (via replanner) | Low | Medium (joiner) |
| Parallelism | Only native parallel calls | Across independent steps | Batched tool calls | Full DAG scheduling |
| Token efficiency | Low (re-reads history) | Medium | High | High |
| Latency | High for long tasks | Medium | Low | Lowest when parallelisable |
| Best for | Exploratory, interactive | Long multi-stage tasks with HITL | Predictable retrieval | Many independent lookups |
| Main failure | Loops, myopia | Stale plans | Early-step invalidation | Planner DAG errors |

## 3.7 Self-Refine

**Paper**: Madaan et al., 2023.

**Mechanics**: the same model generates output, critiques it with feedback, then refines using the feedback, iterating until a stop condition. No training, no external signal.

```python
def self_refine(task, llm, max_iters=3):
    draft = llm(f"Task: {task}\nWrite your best answer.")
    for _ in range(max_iters):
        fb = llm(f"Task: {task}\nAnswer:\n{draft}\n"
                 "List concrete defects (correctness, completeness, format). "
                 "If none, reply exactly: NO_ISSUES")
        if fb.strip() == "NO_ISSUES":
            break
        draft = llm(f"Task: {task}\nAnswer:\n{draft}\nFeedback:\n{fb}\nRewrite fixing every point.")
    return draft
```

> [!WARNING]
> Research (e.g., Huang et al., 2023, *Large Language Models Cannot Self-Correct Reasoning Yet*) showed that **intrinsic** self-correction without external feedback often fails to improve, and can degrade, reasoning accuracy: the model "corrects" right answers into wrong ones. Self-refinement works reliably for *style, format and completeness* criteria, and for reasoning only when grounded in an external signal (tests, compilers, validators, retrieval).

## 3.8 Reflexion

**Paper**: Shinn et al., 2023, *Reflexion: Language Agents with Verbal Reinforcement Learning*.

**Mechanics**: across *trials*, an agent attempts a task, an **evaluator** (unit tests, exact-match, heuristic or LLM judge) scores it, and a **self-reflection** model writes a natural-language lesson ("I failed because I assumed the list was sorted; next time check"). Lessons are stored in **episodic memory** and prepended to the next trial. This is "RL" with the gradient replaced by text in the context window.

```
trial 1 -> evaluator: FAIL (test_empty_input) -> reflection: "handle empty input before indexing"
trial 2 (memory: [reflection_1]) -> evaluator: PASS
```

Reflexion's headline results came from coding (HumanEval) where the evaluator is *external and reliable* (test execution). This is the key insight: reflection is only as good as the feedback signal.

**Production uses**: coding agents that run tests and retry; data-pipeline agents that validate schemas; cross-session "lessons learned" memories (e.g., per-repo instruction files such as `CLAUDE.md`/`AGENTS.md` that accumulate corrections).

> [!TIP]
> Reflexion-style memory across *sessions* is powerful but dangerous: a wrong lesson persists and poisons future runs. Version lessons, attach provenance (which trial, which evaluator), expire them, and evaluate with and without memory to detect drift.

## 3.9 Tree-of-Thoughts (ToT)

**Paper**: Yao et al., 2023.

**Mechanics**: treat reasoning as search over a tree whose nodes are partial solutions ("thoughts"). At each node: **generate** k candidate next thoughts; **evaluate** each (LLM value estimate: "sure/likely/impossible", or a vote); **search** with BFS (keep top-b per level, beam search) or DFS with backtracking.

```
                     root
          /           |           \
       t1(0.8)     t2(0.3)      t3(0.7)        <- generate k=3, evaluate
       /    \                    /    \
   t1a(.9) t1b(.2)          t3a(.4) t3b(.6)    <- expand top b=2
     |
   solution
```

```python
def tree_of_thoughts(problem, llm, k=3, beam=2, depth=3):
    frontier = [""]
    for _ in range(depth):
        candidates = []
        for partial in frontier:
            for t in llm.sample_n(f"{problem}\nSo far:{partial}\nNext step:", n=k, temperature=0.8):
                cand = partial + "\n" + t
                score = llm.score(f"{problem}\nPartial solution:{cand}\n"
                                  "Rate 0-10 how likely this leads to a correct solution.")
                candidates.append((score, cand))
        frontier = [c for _, c in sorted(candidates, reverse=True)[:beam]]
    return llm(f"{problem}\nBest reasoning:{frontier[0]}\nFinal answer:")
```

Cost: roughly `depth × beam × k × 2` calls. On Game of 24, the paper reported GPT-4 success going from 4% (CoT) to 74% (ToT).

**Today**: reasoning models internalise much of this search in their hidden chain of thought (they backtrack, verify and try alternatives), so explicit ToT over a reasoning model rarely pays off for pure reasoning tasks. Explicit search remains valuable when **evaluation is external** (a compiler, a simulator, a proof checker, a test suite) or when you need **diversity** across candidates.

## 3.10 Graph-of-Thoughts (GoT)

**Paper**: Besta et al., 2023.

**Mechanics**: generalises ToT from a tree to an arbitrary graph. Thoughts can be **aggregated** (merge several partial solutions into one), **refined** (self-loops) and **generated**. This models divide-and-conquer: e.g., sort subarrays independently, then merge them; summarise document chunks, then merge summaries.

```
 chunk1 -> summary1 \
 chunk2 -> summary2  >-- aggregate --> refine --> final
 chunk3 -> summary3 /
```

In practice, GoT's practical descendant is the **map-reduce / orchestrator-workers** pattern with explicit merge steps, which you will implement as a graph in LangGraph or as fan-out/fan-in in Temporal far more often than via the GoT framework itself.

## 3.11 LATS (Language Agent Tree Search)

**Paper**: Zhou et al., 2023, *Language Agent Tree Search Unifies Reasoning, Acting, and Planning*.

**Mechanics**: combines ReAct (acting in an environment), ToT (search), Reflexion (self-reflection on failures) and **Monte Carlo Tree Search**. Each node is an agent state (trajectory so far). The algorithm loops:

1. **Select** a node via UCT: `UCT(s) = V(s) + c·sqrt(ln N(parent) / N(s))`.
2. **Expand** by sampling n candidate actions from the LLM.
3. **Evaluate** new nodes with an LLM value function plus self-consistency.
4. **Simulate** to a terminal state.
5. **Backpropagate** the reward (environment reward if available, e.g. tests passing).
6. **Reflect** on failed trajectories; store reflections to guide future expansions.

Reported strong results on HumanEval and WebShop at the time, at large compute cost.

> [!WARNING]
> LATS and other environment-level search require the ability to **reset or fork environment state**. That is trivial for pure functions and code-in-sandbox, but impossible for real side effects (you cannot "un-send" an email to explore a sibling branch). Only apply tree search over actions that are side-effect-free, or over a simulated/sandboxed copy of the environment (snapshotted containers, database transactions rolled back, browser contexts cloned).

## 3.12 Comparison of Search and Reflection Architectures

| Architecture | Structure | Feedback source | Relative cost | Use in 2026 production |
|---|---|---|---|---|
| CoT | Single chain | None | 1x | Subsumed by reasoning models |
| Self-consistency | N parallel chains, majority vote | Agreement | Nx | Classification, math; cheap to parallelise |
| Self-Refine | Iterative chain | Self-critique | 2-3x per iteration | Format/style polish |
| Reflexion | Multi-trial with memory | External evaluator | Trials x base | Coding with tests; cross-session lessons |
| ToT | Tree, BFS/DFS | LLM value or external | 10-100x | Niche; when external verifier exists |
| GoT | DAG with aggregation | LLM or external | Varies | As map-reduce patterns |
| LATS | MCTS over actions | Env reward + LLM value | 50-500x | Offline: data generation, hard benchmarks |

> [!TIP]
> The most important staff-level heuristic about search architectures: **search is only as good as the verifier**. If you have a cheap, reliable verifier (tests, type checker, schema validator, exact-match, solver), best-of-N or tree search converts compute into accuracy almost linearly in log(N). If your only verifier is the same LLM judging itself, gains plateau quickly and can reverse. Invest in verifiers before search.

## 3.13 Best-of-N and Self-Consistency: The Underrated Baseline

Before building elaborate trees, try sampling N independent full solutions in parallel and choosing via majority vote (self-consistency, Wang et al., 2022) or a verifier. It is embarrassingly parallel, so wall-clock latency barely increases, and it is often within a few points of complex search at a fraction of the engineering cost.

```python
import asyncio, collections

async def best_of_n(prompt, llm, n=5, verifier=None):
    outs = await asyncio.gather(*[llm.agenerate(prompt, temperature=0.9) for _ in range(n)])
    if verifier:
        scored = [(verifier(o), o) for o in outs]
        return max(scored, key=lambda x: x[0])[1]
    answers = [extract_final(o) for o in outs]
    return collections.Counter(answers).most_common(1)[0][0]
```


# 4. Composable Workflow Patterns

Anthropic's *Building Effective Agents* identifies five workflow patterns that, combined with the autonomous agent loop, cover the vast majority of production systems. They are composable: an orchestrator's worker can itself be an evaluator-optimizer loop containing a router.

## 4.1 Prompt Chaining

**Mechanics**: decompose a task into a fixed sequence of LLM calls, each consuming the previous output. Insert programmatic **gates** (validation checks) between steps.

```
input -> [LLM: outline] -> gate(outline valid?) -> [LLM: draft] -> [LLM: translate] -> output
                               | fail
                               v
                            retry / abort
```

```python
def chain(doc: str) -> str:
    outline = llm.structured(Outline, f"Outline this doc:\n{doc}")
    if len(outline.sections) < 3:                     # programmatic gate
        raise ValueError("Outline too thin")
    draft = llm(f"Write marketing copy from outline:\n{outline.model_dump_json()}")
    if contains_banned_claims(draft):                 # policy gate
        draft = llm(f"Remove unverifiable claims:\n{draft}")
    return llm(f"Translate to German, keep formatting:\n{draft}")
```

**Why it works**: each call has a narrower job, so it is easier to prompt, test and swap models per step. You trade latency for accuracy.

## 4.2 Routing

**Mechanics**: classify the input and dispatch to a specialised downstream prompt, tool set or model. Separation of concerns: optimising one route does not regress others.

```python
from typing import Literal
from pydantic import BaseModel

class Route(BaseModel):
    intent: Literal["billing", "technical", "account", "other"]
    complexity: Literal["simple", "complex"]
    confidence: float

def route(query: str):
    r = small_llm.structured(Route, f"Classify:\n{query}")
    if r.confidence < 0.6:
        return generalist_agent(query)
    model = "small" if r.complexity == "simple" else "frontier"
    return HANDLERS[r.intent](query, model=model)
```

**Model routing** (send easy queries to cheap models, hard to frontier/reasoning models) is one of the highest-ROI cost optimisations: a well-calibrated router frequently cuts spend 40-70% with negligible quality loss.

> [!WARNING]
> Routers fail silently. A misrouted query gets a confident answer from the wrong specialist. Log router decisions with confidence, sample misroutes into your eval set weekly, and always include an `other`/fallback class. Routers trained or prompted months ago drift as product surface grows.

## 4.3 Parallelization

Two variants:

- **Sectioning**: split a task into independent subtasks run in parallel (e.g., one call screens for policy violations while another answers the query; guardrails in parallel with generation).
- **Voting**: run the same task N times for diverse outputs or confidence (e.g., several vulnerability reviewers; flag if any flags).

```python
async def answer_with_guardrail(q):
    answer_t = asyncio.create_task(main_llm.agenerate(q))
    safe_t = asyncio.create_task(guard_llm.aclassify(q))
    safe = await safe_t
    if not safe.ok:
        answer_t.cancel()
        return REFUSAL
    return await answer_t
```

The OpenAI Agents SDK's **input guardrails** follow this pattern: they run concurrently with the agent and raise a tripwire exception that halts the run if violated.

## 4.4 Orchestrator-Workers

**Mechanics**: a central LLM dynamically decomposes the task, delegates subtasks to worker LLMs (often with their own tools and fresh contexts), and synthesises results. Unlike parallelization, subtasks are *not predefined*; the orchestrator decides them per input.

```
                 +--------------+
     goal -----> | Orchestrator | ---- synthesize ----> answer
                 +--------------+
                  /     |      \        (dynamic number of subtasks)
          +--------+ +--------+ +--------+
          |Worker 1| |Worker 2| |Worker k|   each: own context, tools, budget
          +--------+ +--------+ +--------+
```

Anthropic's multi-agent Research system (described in their June 2025 engineering post) is the canonical example: a lead agent plans, spawns parallel subagents that each search independently with clean contexts, and condenses their findings. They reported large gains on breadth-first research tasks, and also that multi-agent runs consumed roughly 15x the tokens of chat interactions, and that token usage explained most of the performance variance.

Key mechanism: **context isolation**. Each worker spends many tokens exploring but returns a compact summary, so the orchestrator's context stays clean. Multi-agent is primarily a *context-management* technique and a *parallelism* technique, not a "team of personalities" technique.

> [!TIP]
> Use orchestrator-workers when work is **breadth-first and parallelisable** with low inter-worker dependency (research, codebase-wide analysis, many-file migrations). Avoid it for tightly coupled tasks (most single-feature coding), where workers need each other's evolving context and coordination costs dominate. Cognition's widely discussed "Don't Build Multi-Agents" essay makes the counterpoint: share full traces, and prefer a single-threaded agent when decisions are interdependent.

## 4.5 Evaluator-Optimizer

**Mechanics**: one LLM generates; another evaluates against explicit criteria and returns feedback; loop until accepted or budget exhausted. This is Self-Refine with a separated (often differently prompted or different-model) critic, ideally augmented with deterministic checks.

```python
class Verdict(BaseModel):
    accept: bool
    issues: list[str]
    score: int  # 1-10

def evaluator_optimizer(task, gen, judge, max_rounds=4, threshold=8):
    out, history = gen(task), []
    for r in range(max_rounds):
        checks = run_deterministic_checks(out)           # lint, schema, tests
        v = judge.structured(Verdict, rubric_prompt(task, out, checks))
        history.append(v)
        if v.accept and v.score >= threshold and checks.ok:
            return out, history
        if r > 0 and v.score <= history[-2].score:      # no improvement -> stop early
            break
        out = gen(task, previous=out, feedback=v.issues + checks.errors)
    return best_by_score(history), history
```

**When it fits**: clear evaluation criteria exist, and iterative refinement measurably helps (literary translation, code that must pass tests, SQL that must execute, documents with compliance rubrics).

## 4.6 Pattern Selection Matrix

| Pattern | Control flow decided by | Latency | Cost | Best signal it fits |
|---|---|---|---|---|
| Prompt chaining | Code | Sum of steps | Low-medium | Task naturally decomposes into fixed stages |
| Routing | Classifier LLM, then code | +1 small call | Can reduce cost | Distinct input categories with different handling |
| Parallelization | Code | Max of branches | N x | Independent aspects or need for confidence |
| Orchestrator-workers | LLM | Plan + max(workers) + synth | High | Unpredictable subtask set, breadth-first |
| Evaluator-optimizer | Code loop with LLM judge | Rounds x (gen + eval) | Medium-high | Clear rubric; iteration improves output |
| Autonomous agent | LLM | Unbounded (capped) | Unbounded (capped) | Open-ended, many steps, environment feedback |

# 5. State-Machine and Graph-Based Control

## 5.1 Why Graphs

Once an agentic system has more than one loop, conditional branches, human approvals and retries, ad-hoc `while` loops become unmaintainable. The industry converged on modelling agents as **explicit state machines / graphs**:

- **Nodes** are units of work (an LLM call, a tool execution, a sub-agent, a human approval).
- **Edges** are transitions, either fixed or **conditional** (a function of state, possibly of the LLM's output).
- **State** is a typed object passed and reduced across nodes.
- **Checkpoints** persist state after each step, enabling resume, time-travel debugging and human-in-the-loop interrupts.

LangGraph is the most prominent library built on this model (inspired by Pregel/BSP: nodes run in "super-steps", writing to state channels with reducer functions). Google ADK offers `SequentialAgent`, `ParallelAgent` and `LoopAgent` workflow agents composed with `LlmAgent`s. The OpenAI Agents SDK takes a lighter approach (agents plus **handoffs** plus agents-as-tools) with control flow emerging from the model; you write graph logic in plain Python around it. Temporal provides durable execution for the same structures at the infrastructure level.

## 5.2 A LangGraph Example

The following uses LangGraph's `StateGraph` API (stable since 1.0). It implements a ReAct agent with a human-approval gate before sensitive tools.

```python
from typing import Annotated, TypedDict
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode
from langgraph.checkpoint.memory import InMemorySaver   # use a Postgres saver in prod
from langgraph.types import interrupt

class State(TypedDict):
    messages: Annotated[list, add_messages]   # reducer: append
    steps: int

SENSITIVE = {"issue_refund", "delete_account"}

def call_model(state: State):
    resp = model_with_tools.invoke(state["messages"])
    return {"messages": [resp], "steps": state["steps"] + 1}

def route_after_model(state: State):
    last = state["messages"][-1]
    if state["steps"] >= 15:
        return END
    if not getattr(last, "tool_calls", None):
        return END
    if any(tc["name"] in SENSITIVE for tc in last.tool_calls):
        return "approve"
    return "tools"

def approve(state: State):
    last = state["messages"][-1]
    decision = interrupt({"pending_calls": last.tool_calls})  # pauses; resumes with human input
    if decision != "approve":
        return {"messages": [rejection_tool_messages(last, decision)]}
    return {}

def route_after_approval(state: State):
    return "model" if is_rejection(state["messages"][-1]) else "tools"

g = StateGraph(State)
g.add_node("model", call_model)
g.add_node("tools", ToolNode(TOOLS))
g.add_node("approve", approve)
g.add_edge(START, "model")
g.add_conditional_edges("model", route_after_model, ["tools", "approve", END])
g.add_conditional_edges("approve", route_after_approval, ["tools", "model"])
g.add_edge("tools", "model")
app = g.compile(checkpointer=InMemorySaver())

config = {"configurable": {"thread_id": "ticket-123"}}
app.invoke({"messages": [("user", "Refund order O-9")], "steps": 0}, config)
# ...later, after human review: app.invoke(Command(resume="approve"), config)
```

## 5.3 Explicit FSM Without a Framework

For many teams, a small typed state machine in plain code is clearer than a framework and easier to run inside Temporal activities or a queue worker.

```python
from enum import Enum, auto

class S(Enum):
    TRIAGE = auto(); GATHER = auto(); PROPOSE = auto(); APPROVAL = auto()
    EXECUTE = auto(); VERIFY = auto(); DONE = auto(); ESCALATE = auto()

TRANSITIONS = {
    S.TRIAGE:   {S.GATHER, S.ESCALATE},
    S.GATHER:   {S.GATHER, S.PROPOSE, S.ESCALATE},
    S.PROPOSE:  {S.APPROVAL, S.EXECUTE},
    S.APPROVAL: {S.EXECUTE, S.PROPOSE, S.ESCALATE},
    S.EXECUTE:  {S.VERIFY},
    S.VERIFY:   {S.DONE, S.PROPOSE, S.ESCALATE},
}

def step(ctx):
    nxt = HANDLERS[ctx.state](ctx)          # handler may call an LLM to choose
    if nxt not in TRANSITIONS[ctx.state]:
        raise IllegalTransition(ctx.state, nxt)   # LLM cannot jump to EXECUTE from TRIAGE
    ctx.visits[nxt] += 1
    if ctx.visits[nxt] > MAX_VISITS[nxt]:
        nxt = S.ESCALATE
    ctx.state = nxt
    checkpoint(ctx)
```

The key property: the LLM chooses *among allowed transitions*; the graph encodes the invariants (no execution without proposal; verify after every execute). This is "constrained agency" and is how regulated industries deploy agents.

## 5.4 Durable Execution

Agent runs that last minutes to days, wait for humans, or call flaky APIs need **durable execution**: if the process dies, the run resumes from the last completed step without re-executing side effects. Options:

| Approach | Mechanism | Strengths | Weaknesses |
|---|---|---|---|
| LangGraph checkpointer | Persist state per super-step (Postgres/Redis) | Native HITL interrupts, time travel | Side-effect idempotency is on you |
| Temporal | Event-sourced workflow history; activities retried; deterministic replay | Battle-tested, retries, timers, signals; official integrations with OpenAI Agents SDK | Determinism constraints on workflow code; ops overhead |
| Queue + DB state | Each step a job; state row updated transactionally | Simple, familiar | You rebuild retries, timers, visibility |
| Provider-hosted (e.g., OpenAI Responses with stored state, managed agent runtimes) | Server-side conversation state | Least code | Vendor lock-in, limited control |

> [!WARNING]
> LLM calls are nondeterministic. In Temporal, LLM calls and tool executions **must** be activities, never inline in workflow code, otherwise replay produces different decisions and the workflow fails with nondeterminism errors. Equally, make every side-effecting tool idempotent (idempotency keys derived from run ID + step ID), because retries *will* happen.

> [!TIP]
> A graph is also your **observability schema**. Name nodes meaningfully and emit a span per node (OpenTelemetry GenAI semantic conventions are now broadly supported by LangSmith, Langfuse, Arize Phoenix, Logfire and the major SDKs). When an incident happens, "40% of runs loop between VERIFY and PROPOSE" is actionable; "the agent got confused" is not.

# 6. Reasoning Models vs Non-Reasoning Models

## 6.1 What a Reasoning Model Is

A **reasoning model** is trained, typically with large-scale reinforcement learning on verifiable rewards, to produce an extended internal chain of thought before its answer, and to use that chain productively: decomposing, checking, backtracking and trying alternatives. Lineage:

- **OpenAI o-series** (o1 in late 2024, then o3, o4-mini) and the GPT-5 family, where reasoning is controlled with a `reasoning.effort` parameter (`minimal`/`low`/`medium`/`high` in the Responses API, with the exact enum varying by model). Raw reasoning tokens are hidden; summaries can be requested.
- **Anthropic Claude extended thinking** (from Claude 3.7 Sonnet, through Claude 4.x): enabled with `thinking={"type": "enabled", "budget_tokens": N}`; returns `thinking` content blocks (summarised in Claude 4 models) with cryptographic signatures that must be passed back unmodified in multi-turn tool use.
- **Google Gemini thinking** (Gemini 2.5 Pro/Flash, Gemini 3): controlled via `thinking_config` (a `thinking_budget` token count on 2.5 models, where `0` disables thinking on Flash and `-1` requests dynamic budgeting; newer models expose a coarser `thinking_level`). Thought summaries are optional via `include_thoughts`.
- **Open-weight**: DeepSeek-R1 (January 2025) publicly demonstrated that GRPO-based RL on verifiable rewards could produce o1-class reasoning, followed by Qwen3 thinking modes, and others; these expose raw reasoning tokens.

## 6.2 How They Are Trained (Why They Behave as They Do)

The core recipe, popularised by DeepSeek-R1 and widely replicated:

1. Start from a strong pretrained base (optionally a cold-start SFT on long CoT examples for readability).
2. **RLVR (Reinforcement Learning from Verifiable Rewards)**: sample many solutions to problems with automatically checkable answers (math with known results, code with unit tests, formatted outputs). Reward = correctness (+ format).
3. **GRPO (Group Relative Policy Optimization)**: for each prompt, sample a group of G outputs, compute each reward, and use the group-normalised advantage `A_i = (r_i - mean(r)) / std(r)` instead of a learned value critic. This removes the critic model from PPO and makes RL at scale cheaper.
4. Emergent behaviours appear: longer reasoning on harder problems, self-verification, "wait, let me reconsider" backtracking.
5. Further RL for helpfulness/harmlessness, plus, increasingly, **agentic RL** in tool environments (browsing, code execution, terminals) so the model learns to interleave thought with tool calls.

Consequences for engineers:

- Reasoning models are strongest on domains resembling their RL environments: math, code, logic, structured analysis, multi-step tool use.
- They tend to **ignore or fight micro-managing prompts** ("think step by step", rigid CoT templates); the guidance from OpenAI and Anthropic is to give high-level goals and constraints and let the model reason.
- They can **overthink** simple tasks: spending thousands of tokens on a classification.

## 6.3 Test-Time Compute and Scaling

The central idea: accuracy can be bought at inference time, not only at training time. There are two orthogonal axes:

- **Sequential (depth)**: longer single reasoning chains (thinking budget, effort level). Improves with roughly log-linear returns on hard problems, then plateaus.
- **Parallel (breadth)**: sample N chains, select via vote or verifier (best-of-N, self-consistency, tree search). Also roughly log-linear, conditional on verifier quality.

Snell et al. (2024, *Scaling LLM Test-Time Compute Optimally...*) showed that the **compute-optimal** allocation depends on problem difficulty: easy problems benefit from sequential revision, hard ones from parallel search with a good verifier, and adaptive allocation can beat a 14x larger model in FLOPs-matched comparisons on some tasks.

```
accuracy
   ^                                 ___________  plateau (model capability ceiling)
   |                         _______/
   |                 _______/
   |         _______/
   |  ______/
   +------------------------------------------------> log(thinking tokens or N samples)
      cheap tasks saturate here ^         hard tasks still gaining ^
```

## 6.4 Choosing: Reasoning vs Non-Reasoning

| Dimension | Non-reasoning (or thinking off) | Reasoning (thinking on) |
|---|---|---|
| Time-to-first-visible-token | Low (hundreds of ms) | High (seconds to minutes) |
| Cost per task | Low | 2-20x higher (thinking tokens billed as output) |
| Multi-step logic, math, code | Weaker; needs scaffolding | Strong |
| Instruction following on simple formats | Strong, predictable | Strong, sometimes over-elaborates |
| Planning in agents | Needs explicit planner patterns | Plans implicitly; fewer scaffolds needed |
| Prompt style | Detailed, step-by-step OK | High-level goals; avoid prescribing CoT |
| Few-shot examples | Very effective | Helpful for format; can constrain reasoning |
| Best roles | Router, extractor, summariser, high-QPS chat | Planner, orchestrator, hard tool-use, code, analysis, judge |

> [!TIP]
> The dominant 2026 architecture is **heterogeneous**: a reasoning model (or high effort setting) as the planner/orchestrator and for hard decision points, with fast non-reasoning or low-effort models as workers, extractors and routers. Many frontier models are now *hybrid* (one model, thinking toggled per request), so "which model" often becomes "which effort level per node", which you can tune per graph node against evals.

## 6.5 Thinking Budgets

Budgets cap reasoning tokens. Mechanics differ by provider and must be checked against current docs, but the patterns are stable.

**Anthropic** (extended thinking, Messages API):

```python
resp = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=16000,                                  # must exceed budget_tokens
    thinking={"type": "enabled", "budget_tokens": 8000},  # minimum 1024
    messages=[{"role": "user", "content": problem}],
)
for block in resp.content:
    if block.type == "thinking":
        log_reasoning(block.thinking)                  # summarised on Claude 4-family models
    elif block.type == "text":
        answer = block.text
```

**OpenAI** (Responses API):

```python
resp = openai_client.responses.create(
    model="o4-mini",                         # or a GPT-5-family model
    reasoning={"effort": "medium", "summary": "auto"},
    input=problem,
)
print(resp.output_text)
print(resp.usage.output_tokens_details.reasoning_tokens)
```

**Google Gemini** (google-genai SDK):

```python
from google.genai import types
resp = genai_client.models.generate_content(
    model="gemini-2.5-flash",
    contents=problem,
    config=types.GenerateContentConfig(
        thinking_config=types.ThinkingConfig(thinking_budget=4096, include_thoughts=True)
    ),
)
```

Operational rules:

- Thinking tokens are **billed as output tokens** and count against latency, even when hidden or summarised.
- With temperature/top-p, many providers restrict sampling parameters when thinking is enabled; check before you rely on them.
- Budgets are *ceilings and hints*, not exact targets; models often use less on easy problems.
- Budget selection should be **empirical**: sweep budgets on your eval set and plot accuracy vs cost and p95 latency; pick the knee.

> [!WARNING]
> Truncated thinking is worse than no thinking. If `max_tokens` (or the output cap) is too close to the thinking budget, the model can exhaust its output allowance mid-reasoning and return an empty or partial answer (`stop_reason == "max_tokens"`, OpenAI `status: incomplete`). Always leave generous headroom for the final answer and handle the incomplete case explicitly (retry with a higher cap or lower effort).

## 6.6 Interleaved Thinking with Tool Use

Early reasoning models thought once, then answered. Agentic use requires **interleaved thinking**: reasoning *between* tool calls, about each observation.

```
user goal
  -> [think] plan: need A and B
  -> tool_call(A)
  <- result A (surprising)
  -> [think] A contradicts assumption; check C before B     <- interleaved reasoning
  -> tool_call(C)
  <- result C
  -> [think] synthesize
  -> final answer
```

Provider mechanics (verify against current docs):

- **Anthropic**: Claude 4-family models support interleaved thinking (initially via the beta header `interleaved-thinking-2025-05-14`). Critically, you must pass the previous assistant turn's `thinking` blocks back **unmodified** (including signatures) with the tool results, or the API rejects the request or reasoning continuity is lost.
- **OpenAI**: o3/o4-mini and GPT-5 models call tools within their chain of thought. In the Responses API, reasoning items are carried across turns either via `previous_response_id` (server-side state) or by passing back encrypted reasoning items (`include=["reasoning.encrypted_content"]`) for stateless/zero-data-retention setups.
- **Gemini**: thinking models return thought signatures that should be preserved across function-calling turns to maintain reasoning context.

> [!WARNING]
> A very common production bug: a framework or custom middleware "cleans" message history by stripping thinking/reasoning blocks to save tokens, or re-serialises them. This silently degrades multi-step tool-use quality (the model loses its plan) or causes API validation errors. Treat reasoning items as opaque, signed artefacts: store and replay them verbatim within a tool-use turn. (Providers may drop thinking from *earlier completed turns* automatically; follow their rules rather than inventing your own.)

## 6.7 Reasoning Models Change Which Scaffolds Pay Off

| Scaffold | With non-reasoning model | With reasoning model |
|---|---|---|
| "Think step by step" prompts | Helps | Redundant, sometimes harmful |
| Explicit planner node | Often essential | Often unnecessary for short tasks; still useful for HITL plan review and long horizons |
| ToT / LATS for reasoning | Large gains | Small gains unless external verifier |
| Self-Refine for logic | Unreliable | Somewhat better, still prefer external checks |
| Best-of-N with verifier | Large gains | Still gains; very effective with tests |
| Few-shot reasoning traces | Helps | Can anchor the model to worse strategies |
| Structured output schemas | Essential | Essential |
| External verifiers (tests, validators) | Essential | Essential |

The general lesson, consistent with Sutton's "bitter lesson": scaffolds that substitute for model capability decay as models improve; scaffolds that add **information** (tools, retrieval, verifiers, environment feedback) or **control** (budgets, permissions, approvals) remain valuable. Design accordingly, and re-evaluate your scaffolds with every model upgrade.

