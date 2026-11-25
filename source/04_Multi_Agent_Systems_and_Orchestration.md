[TOC]

# Part 4 Overview: Multi-Agent Systems and Orchestration

This part of the suite is about the hardest architectural question in agentic engineering: **when should one model loop become several, and once it does, how do you keep the whole system correct, observable, affordable, and recoverable?** Interviewers at Senior/Staff/Lead level rarely want a recital of framework APIs. They want to see that you can reason from first principles about context, cost, failure, and state, and that you know when "multi-agent" is an anti-pattern dressed up as sophistication.

The material is organized as follows:

- **Justification.** The economics and information theory of splitting work across agents, the Anthropic multi-agent research system lessons, and Cognition's "Don't Build Multi-Agents" counter-argument, reconciled into one decision rule.
- **Patterns.** Supervisor, hierarchical, swarm/handoffs, sequential pipelines, debate/critic, blackboard, map-reduce. For each: mechanics, data flow, code, failure modes, trade-offs.
- **State and context.** Shared state schemas, reducers, context passing strategies, memory scoping, and the "telephone game" problem.
- **Reliability engineering.** Durable execution, checkpointing, deterministic replay, Temporal-style workflows, human-in-the-loop interrupts, idempotency and effectively-once side effects, retries, timeouts, sagas and compensation, concurrency and races.
- **Frameworks.** LangGraph, OpenAI Agents SDK, Claude Agent SDK, Google ADK, CrewAI, AutoGen/AG2, and framework-less designs, with code sketches and an honest comparison.
- **Decision matrix and interview drills.**

> [!NOTE]
> Terminology used throughout: an **agent** is an LLM running in a loop with tools, a system prompt, and a termination condition. A **workflow** is a predetermined code path that calls LLMs at fixed points. An **orchestrator** is whatever decides what runs next; it may be code (deterministic) or an LLM (dynamic). Most production "multi-agent systems" are actually workflows with a few agentic nodes, and that is usually the right answer.

## The Core Mental Model: Agents Are Context Boundaries

The single most useful mental model for multi-agent design is this: **an agent is a context window with a purpose.** Splitting work into multiple agents is fundamentally a decision about how to partition information across context windows. Everything else (roles, personas, "teams") is secondary.

That reframing produces three immediate consequences:

1. **Splitting buys you parallelism and context isolation.** Each sub-agent gets a fresh, focused window. It can burn 100K tokens exploring and return a 2K-token distillate. The parent never sees the noise.
2. **Splitting costs you shared understanding.** Every boundary is a lossy compression step. Decisions made implicitly inside one agent's context (style choices, assumptions, rejected hypotheses) do not cross the boundary unless explicitly serialized.
3. **Splitting multiplies tokens.** Each agent re-reads its system prompt, tool definitions, and task framing, and every handoff re-encodes context. Multi-agent systems routinely consume 4x to 15x the tokens of a single-agent approach.

So the design question is never "how many agents would be elegant?" It is: **is the information this task needs naturally partitionable, such that sub-units can work with minimal shared context and return compressed results?** If yes, multi-agent can win. If the sub-units need to constantly agree on fine-grained, evolving decisions, a single agent with good context management almost always wins.

```
Single agent                         Orchestrator + workers
+---------------------------+        +-------------------+
| system + tools            |        | lead context      |
| task                      |        |  plan             |
| step1 obs (noise+signal)  |        |  summary_A (2K)   |
| step2 obs                 |        |  summary_B (2K)   |
| ... grows to 200K         |        |  summary_C (2K)   |
| context rot / degradation |        +---------+---------+
+---------------------------+           /      |      \
                                   [A 80K] [B 60K] [C 90K]   <- isolated, discarded
Total tokens: ~200K                Total tokens: ~240K+ but lead stays sharp
```

> [!TIP]
> In a Staff interview, open any multi-agent design answer with "What is the context partitioning?" before you mention roles. It signals you understand that the unit of design is information flow, not anthropomorphic job titles. "Researcher agent, writer agent, editor agent" is a smell unless you can explain why those contexts must be separate.

# When Multi-Agent Is (and Is Not) Justified

## The Token Cost Multiplier

Let us quantify cost first, because it dominates most decisions.

For a single agent running N turns with system prompt S, tool schema T, and accumulated history H_i at turn i, input tokens are roughly the sum over turns of (S + T + H_i). History grows each turn, so cost is roughly quadratic in turns without compaction, which prompt caching makes far cheaper (cached prefix reads are typically billed at around 10% of the base input rate on major providers) but not free.

For an orchestrator with K workers, you pay:

- Orchestrator planning turns, including reading all worker results.
- For each worker: its own (S_w + T_w) prefix on every turn, plus its own growing history.
- Serialization overhead: task briefs going down, summaries coming up.
- Retries and verification passes, which multiply per worker.

Anthropic publicly reported that in their internal evaluations agents use about 4x more tokens than chat interactions, and multi-agent systems about 15x more than chat. They also found that token usage by itself explained the large majority of performance variance on their browsing evaluation (they cited roughly 80%), with number of tool calls and model choice explaining most of the rest. The implication is subtle and important: **a large part of why multi-agent research systems perform better is that they spend more tokens, in parallel, in clean contexts.** Multi-agent is in part a mechanism for spending more compute without wrecking any single context window.

| Architecture | Typical token multiple vs chat | Latency profile | Where it pays off |
|---|---|---|---|
| Single LLM call | 1x | Lowest | Classification, extraction, rewriting |
| Single agent loop | ~4x | Sequential tool calls | Coding, most tasks with coupled decisions |
| Orchestrator + parallel workers | ~10x to 15x | Wall-clock reduced by parallelism | Breadth-first research, independent subtasks |
| Debate / multi-critic | 2x to 5x of base per round | Rounds add latency | High-stakes verification where errors are expensive |
| Unbounded agent chatrooms | Unbounded | Unpredictable | Almost never in production |

> [!WARNING]
> The most common production failure of multi-agent systems is economic, not technical: a demo that costs \$0.40 per run becomes \$6 per run once retries, verifier passes, and long-tail tasks are counted, and the product's unit economics never close. Always model the p95 token cost per task, not the median, before committing to an architecture.

## The Anthropic Multi-Agent Research System: Lessons

Anthropic's engineering write-up on their Research feature (2025) is the canonical positive case study. Architecture: a **lead agent** (orchestrator-worker pattern) analyzes the query, develops a strategy, and spawns **subagents** that search in parallel, each with its own context window, then returns condensed findings to the lead, which synthesizes and optionally spawns more. A separate **citation agent** pass attributes claims to sources at the end.

Key lessons worth knowing cold:

1. **Breadth-first, parallelizable queries are the sweet spot.** Their multi-agent configuration (Opus lead with Sonnet subagents) outperformed single-agent Opus by about 90% on their internal research eval, especially on queries like "find all board members of the IT companies in the S&P 500" that decompose into independent lookups.
2. **Teach the orchestrator how to delegate.** Early versions spawned 50 subagents for simple queries, or gave vague briefs ("research the semiconductor shortage") so subagents duplicated work. Fix: each subagent brief must include an objective, an output format, guidance on tools and sources, and clear task boundaries.
3. **Scale effort to query complexity.** Embed explicit heuristics in the prompt: simple fact-finding uses 1 agent with 3 to 10 tool calls; direct comparisons use 2 to 4 subagents; complex research uses 10+ subagents with clearly divided responsibilities.
4. **Tool design and descriptions matter enormously.** Agents picking the wrong tool, or a bad tool description, sends whole subtrees off course. They even used a model to rewrite tool descriptions after observing failures, cutting task completion time substantially.
5. **Start wide, then narrow.** Prompt subagents to begin with short, broad queries and progressively narrow, mirroring expert human search.
6. **Extended thinking as a controllable scratchpad.** The lead uses thinking to plan; subagents use interleaved thinking after tool results to evaluate quality and decide next steps.
7. **Parallel tool calling at two levels.** The lead spins up 3 to 5 subagents in parallel; subagents use 3+ tools in parallel. This cut research time by up to 90% for complex queries.
8. **Evaluation: start small, use LLM-as-judge with a rubric, keep humans in the loop.** Early on, effect sizes are huge, so 20 representative queries are enough to see changes. Judges scored factual accuracy, citation accuracy, completeness, source quality, and tool efficiency.
9. **Production reliability is the hard part.** Agents are stateful and errors compound. They built resumption from checkpoints rather than restart, let the model know when a tool fails so it can adapt, and used **rainbow deployments** so in-flight long-running agents were not broken by code changes mid-run.
10. **Synchronous execution is a bottleneck.** The lead waits for each batch of subagents to finish. Asynchronous execution would add parallelism but also adds coordination, state consistency, and error propagation complexity, which they explicitly deferred.
11. **Subagent output to filesystem.** To reduce the "game of telephone," subagents can write artifacts to external storage and pass lightweight references back to the lead, instead of routing everything through the lead's context.

> [!IMPORTANT]
> Anthropic also stated explicitly that multi-agent systems are a poor fit for domains where all agents need the same context or where there are many dependencies between agents, citing **most coding tasks** as an example of less parallelizable work. This is the bridge to Cognition's argument; the two positions are much closer than the blog titles suggest.

## Cognition: "Don't Build Multi-Agents"

Cognition (makers of Devin) published "Don't Build Multi-Agents" (June 2025), arguing that most multi-agent architectures are fragile. Their argument rests on two principles of **context engineering**:

- **Principle 1: Share context, and share full agent traces, not just individual messages.** A subagent given only a task string lacks the decisions, constraints, and reasoning accumulated by the parent.
- **Principle 2: Actions carry implicit decisions, and conflicting decisions carry bad results.** When two agents act in parallel on overlapping concerns, each makes implicit choices (style, assumptions, interfaces) that conflict.

Their canonical example: task "build a Flappy Bird clone," split into "make the background with pipes" and "make the bird." Subagent 1 builds a Super Mario style background; subagent 2 builds a bird that does not look or move like a Flappy Bird asset. The final combiner must reconcile two incompatible sets of implicit decisions. Even if you pass the full original task to both, they still cannot see each other's in-progress decisions.

Their recommendations:

- Default to a **single-threaded linear agent** where context is continuous.
- For very long tasks, introduce a dedicated **context compression** model/step that summarizes history into key details, events, and decisions, instead of fanning out.
- If you use sub-tasks, keep them **read-only or question-answering** in nature (e.g., "find where X is defined"), so they do not make conflicting writes. They noted Claude Code's subagents at the time were used for answering questions, not writing code in parallel.

## Reconciling the Two Positions

The positions are compatible once you see the governing variable: **coupling of implicit decisions across subtasks.**

| Task property | Favors single agent | Favors multi-agent |
|---|---|---|
| Decision coupling | High: outputs must cohere (code, prose voice, design) | Low: subtasks independent (lookups, per-document analysis) |
| Output type of subtask | Writes / mutations to shared artifacts | Reads / information gathering / summaries |
| Context needed per subtask | Most of the global context | Small slice of global context |
| Breadth vs depth | Deep, sequential reasoning | Wide, parallel exploration |
| Value per task | Low or moderate | High enough to absorb 10x tokens |
| Latency requirement | Interactive, tight | Wall-clock matters but tokens are cheap relative to value |
| Verification | Hard to verify parts independently | Parts verifiable independently |

**Decision rule:** Fan out for **reads**, converge for **writes**. Parallelize information gathering into isolated contexts; keep all decisions that must cohere inside one context (one agent, or one synthesizer with authority). This is exactly what the Anthropic research system does (subagents gather, lead synthesizes, citation agent only annotates) and exactly what Cognition endorses (subagents answer questions; one thread writes).

> [!TIP]
> A crisp Staff-level summary: "Multi-agent is a context-scaling and parallelism technique, not an organizational metaphor. I use it when the task is read-heavy and decomposes into low-coupling slices, when the value per task absorbs a ~10x token multiplier, and when I can verify slices independently. For coupled write tasks I use a single agent with compaction, and at most delegate read-only investigations to subagents."

## Other Legitimate Reasons to Split

Beyond parallel breadth, there are good non-parallelism reasons for multiple agents:

- **Security and privilege separation.** A browsing agent that reads untrusted web content should not hold the credentials to send email. Splitting into a quarantined reader and a privileged actor that only sees sanitized, structured output is a prompt-injection defense (the "dual LLM" / CaMeL-style pattern). This is often the strongest justification of all.
- **Tool-count limits.** Tool selection accuracy degrades as tool count grows into the many dozens. Routing to specialist agents, each with 5 to 15 tools, keeps selection accurate. (Tool search / deferred tool loading features are an alternative.)
- **Model heterogeneity.** A cheap fast model for triage and extraction, a reasoning model for planning, a vision model for computer use. Different agents let you pick per-step cost/quality points.
- **Organizational ownership.** Different teams own different agents behind stable contracts (this is where A2A shines). This is Conway's law, and it is a real reason, but it should map to service boundaries rather than prompt boundaries.
- **Independent verification.** A critic with a different prompt, different model, or no access to the generator's reasoning reduces correlated errors.
- **Context-window relief on long tasks.** A subagent can perform a noisy sub-investigation (read 40 files, run 15 test commands) and return only the conclusion.

## Anti-Signals: When Not to Go Multi-Agent

- You cannot write down the interface (input schema, output schema) between agents. If the contract is "they chat until done," you have not designed a system.
- Most agents need the full conversation to do their job.
- The "agents" differ only by persona text ("You are a senior QA engineer") and share the same tools and model. That is a prompt, not an architecture.
- You have no evaluation harness yet. Multi-agent amplifies variance; without evals you cannot tell if a change helped.
- The task is latency-critical and sequential. Handoffs add round trips with no parallelism gain.
- The single-agent baseline has not been tried and measured. Always build the baseline first.

> [!WARNING]
> "Agent chatrooms" where N role-played agents converse freely in a group chat until someone says TERMINATE are the classic research-demo-to-production failure. Symptoms: loops of politeness ("Great point! Building on that..."), premature termination, unbounded cost, and non-reproducible outcomes. If you use group-chat style orchestration, bound it with a deterministic speaker selector, max turns, and a structured termination check.

# Multi-Agent Patterns

This section covers the main topologies. For each, think about four things: **who decides control flow, what state is shared, how context crosses boundaries, and how failures propagate.**

```
Control-flow authority spectrum

Deterministic code ------------------------------------------- LLM decides
  sequential     map-reduce     supervisor (router)   swarm/handoffs   group chat
  pipeline       (fan-out)      hierarchical          (peer-to-peer)   (emergent)

  more predictable, testable, cheap  <------->  more adaptive, costly, fragile
```

> [!TIP]
> Push control-flow authority as far left as the task allows. Every decision you move from an LLM into code is one fewer source of variance, one more thing unit-testable, and one fewer token-consuming turn. The art is to use LLM-decided routing only where the branching truly depends on semantic content you cannot classify cheaply.

## Pattern 1: Supervisor (Orchestrator-Worker)

**Mechanics.** A central supervisor agent receives the task, decides which worker(s) to invoke, gives each a brief, receives results, and decides whether to invoke more workers or finish. Workers do not talk to each other; all communication is hub-and-spoke through the supervisor.

There are two implementation flavors:

1. **Agents-as-tools.** Workers are exposed to the supervisor as tools (`research(query) -> summary`). The supervisor's conversation stays continuous; worker runs are nested and ephemeral. Control always returns to the supervisor.
2. **Graph supervisor.** The supervisor is a node in a graph that emits a routing decision (`next = "coder"`), and edges route state to the chosen worker node, which then routes back to the supervisor. State is shared via a graph state object.

```
              +-------------+
   task ----> | Supervisor  | <-----------------+
              +------+------+                   |
          brief /    | brief   \ brief          | results (compressed)
               v     v          v               |
          [Worker A] [Worker B] [Worker C] -----+
          own ctx    own ctx    own ctx
```

**Agents-as-tools sketch (framework-agnostic pseudocode):**

```python
# Framework-agnostic pseudocode
from dataclasses import dataclass

@dataclass
class Brief:
    objective: str
    output_format: str
    boundaries: str          # what NOT to do, to avoid overlap
    tool_hints: list[str]
    budget_tool_calls: int

def run_worker(brief: Brief, worker_cfg) -> dict:
    """Runs an isolated agent loop; returns a structured, compressed result."""
    messages = [
        {"role": "system", "content": worker_cfg.system_prompt},
        {"role": "user", "content": render_brief(brief)},
    ]
    result = agent_loop(messages, tools=worker_cfg.tools,
                        max_steps=brief.budget_tool_calls,
                        output_schema=worker_cfg.output_schema)
    return result  # e.g. {"findings": [...], "sources": [...], "confidence": 0.7}

SUPERVISOR_TOOLS = [
    tool_from_fn("delegate_research", lambda **kw: run_worker(Brief(**kw), RESEARCHER)),
    tool_from_fn("delegate_data_analysis", lambda **kw: run_worker(Brief(**kw), ANALYST)),
]
```

**Strengths.** Single point of control makes it easy to reason about termination, budget, and final output quality. Workers are stateless relative to each other, which simplifies retries. Naturally supports parallel fan-out when the supervisor emits multiple tool calls in one turn.

**Weaknesses.** The supervisor is a bottleneck for context: every worker result passes through its window. With many workers or verbose results, the supervisor itself suffers context rot. It is also a single point of reasoning failure: a bad plan sends all workers in the wrong direction.

> [!WARNING]
> **Supervisor paraphrase loss.** When the supervisor rewrites a worker's answer for the user, it can silently drop caveats, numbers, or citations. LangChain's own benchmarking of supervisor architectures found that letting workers' final responses be forwarded directly (instead of re-generated by the supervisor) measurably improved results. Provide a "forward_message" path for outputs that should reach the user verbatim.

> [!WARNING]
> **Brief underspecification.** "Look into competitor pricing" yields duplicated work across workers and inconsistent formats. Enforce briefs through a schema (objective, output format, boundaries, budget) and validate it before spawning. Treat a brief like an API request, not a chat message.

## Pattern 2: Hierarchical (Supervisor of Supervisors)

**Mechanics.** Supervisors manage teams, and a top-level supervisor manages team leads. This mirrors org charts and is used when the number of specialists exceeds what one supervisor can route among reliably, or when teams have distinct tool sets and evaluation criteria.

```
                    [Top Supervisor]
                    /               \
          [Research Lead]        [Engineering Lead]
          /     |      \           /         \
     [Web]  [Papers] [Internal]  [Coder]   [Tester]
```

**When justified.** Tool counts or domain breadth too large for one router; teams with genuinely different SLAs (e.g., a compliance sub-team that must use a specific approved model); or separately deployed agent services where each lead is an A2A endpoint owned by a different team.

**Costs.** Each level adds a compression step and a round trip. Three levels deep, the leaf worker is executing an instruction that is a summary of a summary of the user's request. Latency stacks; token costs stack; error attribution becomes hard.

> [!TIP]
> Limit hierarchies to two levels in most designs. If you think you need three, check whether the middle layer is doing real decision-making or just routing that a deterministic classifier could do. Replacing an LLM "team lead" with a code router plus a typed contract usually improves both reliability and cost.

> [!WARNING]
> **Goal drift through layers.** Constraints stated by the user ("must use only 2025 data", "no external APIs") frequently disappear two levels down. Carry a structured, immutable `constraints` object through every level in state, and have leaf agents receive it verbatim rather than paraphrased.

## Pattern 3: Swarm with Handoffs (Peer-to-Peer)

**Mechanics.** There is no central supervisor. Each agent can transfer control to another agent via a handoff (typically modeled as a tool call such as `transfer_to_billing`). The active agent owns the conversation until it hands off. The conversation history (or a filtered version) moves with the handoff. OpenAI's experimental Swarm library popularized this, and the OpenAI Agents SDK productionized it as `handoffs`. LangGraph provides `langgraph-swarm`, and AutoGen AgentChat has a `Swarm` team built on `HandoffMessage`.

```
user <-> [Triage] --handoff--> [Billing] --handoff--> [Refunds]
                \--handoff--> [Tech Support] --handoff--> [Triage]
   (only one agent is "active" at a time; history travels with control)
```

**Key distinction from agents-as-tools:** with a handoff, the receiving agent takes over the conversation and responds to the user directly; control does not automatically return. With agents-as-tools, the callee returns a result to the caller, who remains in charge.

**Strengths.** Very natural for customer-service style routing, where the specialist should talk directly to the user. Avoids supervisor paraphrase loss. Each agent has a small, focused tool set and prompt.

**Weaknesses.**

- **Ping-pong loops.** Agent A hands to B, B decides it is A's job, hands back.
- **Global invariants have no owner.** Nobody is accountable for "the whole conversation."
- **History bloat.** Passing full history on every handoff means the 5th agent carries everything.
- **Hard to evaluate.** Paths vary per conversation.

> [!WARNING]
> Always bound handoffs: a max-handoff counter in state, a rule that an agent cannot hand back to its immediate predecessor without new information, and a fallback "human escalation" agent. Log the handoff graph per conversation and alert on cycles.

**Mitigations for history bloat.** Use input filters on handoff (strip tool calls, keep only user-visible messages, or summarize). The OpenAI Agents SDK supports an `input_filter` on a handoff, and ships helpers such as `handoff_filters.remove_all_tools`. Alternatively, pass a structured handoff payload (reason, customer_id, issue summary) as handoff input data validated against a schema.

## Pattern 4: Sequential Pipeline (Prompt Chaining)

**Mechanics.** A fixed sequence of steps, each an LLM call or agent, where the output of step i is the input of step i+1. Control flow is entirely in code. Gates between steps validate outputs and can short-circuit.

```
input -> [Extract] -> gate(schema ok?) -> [Enrich] -> gate -> [Draft] -> [Review] -> output
                         |fail                                  |fail
                         v                                      v
                    retry/repair                           loop back to Draft (max 2)
```

This is the "workflow" end of the spectrum and is the right default whenever the steps are known in advance. Anthropic's "Building Effective Agents" guidance explicitly recommends starting here (prompt chaining, routing, parallelization) before reaching for autonomous agents.

```python
# Plain Python pipeline with typed gates
from pydantic import BaseModel, ValidationError

class Extracted(BaseModel):
    company: str
    fiscal_year: int
    revenue_usd: float | None

class Draft(BaseModel):
    summary: str
    claims: list[str]

def extract(doc: str) -> Extracted:
    raw = llm_json(prompt=EXTRACT_PROMPT.format(doc=doc), schema=Extracted)
    return Extracted.model_validate(raw)

def draft(e: Extracted) -> Draft:
    return Draft.model_validate(llm_json(DRAFT_PROMPT.format(**e.model_dump()), schema=Draft))

def review(d: Draft, source: str) -> list[str]:
    # returns list of unsupported claims
    return llm_json(REVIEW_PROMPT.format(claims=d.claims, source=source), schema=list[str])

def pipeline(doc: str) -> Draft:
    e = with_retries(lambda: extract(doc), on=(ValidationError,), attempts=3)
    d = draft(e)
    for _ in range(2):
        unsupported = review(d, doc)
        if not unsupported:
            return d
        d = draft_with_feedback(e, d, unsupported)
    raise NeedsHumanReview(d, unsupported)
```

**Strengths.** Predictable, cheap, testable step by step, easy to cache, easy to trace. Each step can use the cheapest adequate model.

**Weaknesses.** Rigid; cannot adapt when inputs fall outside the anticipated shape. Errors in early steps propagate (mitigate with gates).

> [!TIP]
> Many systems marketed as "multi-agent" would be strictly better as a pipeline with one agentic node. Ask: "Does any step need to decide which step runs next based on semantics?" If no, it is a pipeline. If only one place does, use a router node there and keep the rest deterministic.

## Pattern 5: Debate, Critic, and Evaluator-Optimizer

**Mechanics.** One agent generates; another critiques; the generator revises. Variants:

- **Evaluator-optimizer loop:** generator plus a rubric-driven evaluator, iterate until pass or budget.
- **Multi-agent debate:** N agents propose answers independently, read each other's answers, and revise over rounds; a judge or majority aggregates. Research (e.g., Du et al. 2023) showed gains on reasoning and factuality benchmarks.
- **Independent verifier:** a separate agent with different context (and ideally different model) checks the output against sources or tests.

```
          +-----------+     draft      +-----------+
 task --> | Generator | ------------>  | Evaluator | -- pass --> output
          +-----------+ <------------  +-----------+
                         critique+score     |
                                            +-- budget exhausted --> best-so-far + flag
```

**What the evidence actually says (as of 2026).** Gains from debate are real but smaller than early papers suggested once you control for compute: several follow-up studies found that self-consistency (sampling N answers and voting) with the same token budget matches or beats debate on many reasoning tasks. With strong reasoning models that already do internal deliberation, naive debate often adds cost for marginal gain. Critics are most valuable when they have **information or capabilities the generator lacks**: running tests, executing code, checking citations against retrieved sources, or seeing the rubric.

| Verification approach | Cost | Catches | Weakness |
|---|---|---|---|
| Self-critique (same model, same context) | Low | Formatting, obvious slips | Correlated errors; sycophancy toward own output |
| Separate critic, same model, fresh context | Medium | Reasoning gaps, missing requirements | Still correlated priors |
| Critic with different model family | Medium | Some model-specific blind spots | Integration cost, calibration differences |
| Tool-grounded verifier (tests, execution, retrieval) | Varies | Factual and functional errors | Requires verifiable signal |
| Self-consistency vote | N x base | Random reasoning errors | Not systematic errors |
| Multi-agent debate | N x rounds x base | Some reasoning errors | Conformity, cost, persuasive-wrong agents |

> [!WARNING]
> **Sycophantic convergence.** In debate, agents tend to converge on the most confident-sounding answer rather than the correct one, and critics often approve after one revision because the generator "addressed the feedback." Mitigate by making critics score against an explicit rubric with required evidence, hiding the generator's reasoning from the critic, and capping rounds.

> [!TIP]
> The highest-ROI critic is a deterministic one. Unit tests, schema validators, link checkers, SQL EXPLAIN, policy engines. Use an LLM critic only for properties you cannot check in code, and make it output structured verdicts (pass/fail per rubric item plus evidence span) rather than prose.

## Pattern 6: Blackboard

**Mechanics.** A shared, structured workspace (the blackboard) holds the current state of the problem: hypotheses, partial solutions, open questions. Independent specialist agents (knowledge sources) watch the blackboard and contribute when they can make progress. A control component decides which contributor runs next, based on blackboard state. This is a classic AI architecture (Hearsay-II, 1970s) that maps well onto LLM agents with a shared state store.

```
          +--------------------------------------------+
          |                BLACKBOARD                  |
          | facts: [...]   hypotheses: [...]           |
          | open_questions: [...]  artifacts: {...}    |
          +----^-----------^-------------^-------------+
               | r/w       | r/w         | r/w
         [Retriever]  [Analyst]     [Verifier]
               \           |             /
                +---- Controller --------+   (picks next contributor based on state)
```

**Compared to supervisor:** the supervisor holds the state in its own context; in blackboard, the state is external and structured, and agents read only the slice they need. This reduces the context bottleneck and makes state inspectable and checkpointable.

**Implementation notes.**

- Store the blackboard in a database or a graph state object with typed sections.
- Each entry has provenance (which agent, which step, which sources) and status (proposed, verified, rejected).
- Use optimistic concurrency (version numbers) for writes.
- The controller can be code (rules on state: "if any hypothesis is unverified, run Verifier") or an LLM.

```python
# Blackboard entry schema
from pydantic import BaseModel, Field
from typing import Literal
from datetime import datetime

class Entry(BaseModel):
    id: str
    kind: Literal["fact", "hypothesis", "question", "artifact"]
    content: str
    sources: list[str] = []
    author_agent: str
    status: Literal["proposed", "verified", "rejected"] = "proposed"
    version: int = 1
    created_at: datetime = Field(default_factory=datetime.utcnow)

def controller(bb) -> str | None:
    if bb.any(kind="question", status="proposed"):
        return "retriever"
    if bb.any(kind="hypothesis", status="proposed"):
        return "verifier"
    if bb.coverage_score() < 0.8:
        return "analyst"
    return None  # done
```

> [!TIP]
> The blackboard is the pattern hiding inside most good "shared memory" multi-agent designs, and it is the bridge to Cognition's concern: a shared, structured decision log lets parallel agents see each other's implicit decisions. If you must parallelize writes, have every agent record its design decisions to the blackboard before acting, and have others read that log first.

## Pattern 7: Map-Reduce (Parallel Fan-Out / Fan-In)

**Mechanics.** Split input into N chunks (map), process each independently in parallel with an identical or parameterized agent, then aggregate (reduce). Splitting can be deterministic (per document, per row) or LLM-driven (planner emits subtasks). LangGraph implements dynamic fan-out with the `Send` API; Google ADK has `ParallelAgent`; plain Python uses `asyncio.gather` with a semaphore.

```
                 +--> [worker(chunk1)] --+
 input -> split -+--> [worker(chunk2)] --+--> reduce -> output
                 +--> [worker(chunkN)] --+
                       (bounded concurrency, per-item retries)
```

```python
import asyncio

SEM = asyncio.Semaphore(8)  # respect provider rate limits

async def map_one(item, attempt_budget=3):
    async with SEM:
        for attempt in range(attempt_budget):
            try:
                return {"id": item.id, "ok": True, "result": await analyze(item)}
            except TransientError:
                await asyncio.sleep(min(2 ** attempt, 20) + jitter())
        return {"id": item.id, "ok": False, "error": "exhausted"}

async def map_reduce(items):
    results = await asyncio.gather(*(map_one(i) for i in items))
    ok = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    if len(failed) / max(len(results), 1) > 0.1:
        raise PartialFailure(failed)       # policy: >10% failure aborts
    return await reduce_hierarchically(ok, fan_in=10)
```

**Reduce design matters more than map.** If the reducer receives 200 summaries in one prompt, you recreate the context problem. Use **hierarchical reduction** (reduce in groups of 10, then reduce the reductions), and make map outputs structured so the reducer can do much of the work in code (dedupe, count, sort) before the LLM synthesizes.

> [!WARNING]
> **Partial failure semantics** must be decided up front: does one failed chunk fail the job, get retried, get skipped with a flag, or get handled by a fallback model? Silent dropping of failed chunks is a classic source of confidently incomplete answers ("I analyzed all contracts" when 7 of 120 timed out).

## Pattern Comparison Table

| Pattern | Control authority | Shared state | Parallelism | Best for | Main risk |
|---|---|---|---|---|---|
| Supervisor | LLM hub | Supervisor context or graph state | Yes, via parallel delegation | Dynamic decomposition, research | Hub context bottleneck, paraphrase loss |
| Hierarchical | LLM tree | Per-team plus top state | Yes | Large domain breadth, multi-team ownership | Goal drift, latency stacking |
| Swarm / handoffs | Active agent | Conversation history | No (one active) | Customer-facing routing | Ping-pong, no global owner |
| Sequential pipeline | Code | Typed step outputs | No (or per-step) | Known procedures, ETL-like tasks | Rigidity |
| Debate / critic | Code loop plus LLM judge | Drafts and critiques | Optional | High-stakes quality | Sycophancy, cost |
| Blackboard | Controller (code or LLM) | External structured store | Yes | Open-ended problem solving, shared decisions | Write conflicts, controller complexity |
| Map-reduce | Code | Chunk results | Massive | Bulk independent items | Reduce overload, partial failure |

> [!TIP]
> Real systems compose patterns. A typical high-quality research product: a sequential outer pipeline (clarify, plan, research, write, cite), whose "research" step is a supervisor doing map-reduce over subagents, whose "write" step is an evaluator-optimizer loop, all over a blackboard-style state store with checkpoints. Name the composition explicitly in interviews.
