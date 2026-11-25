[TOC]

# Context Window Economics and Failure Modes

## Why Context Is the Scarcest Resource in an Agent

An LLM agent is a stateless function called in a loop. Every turn, the model sees *only* what is inside its context window: system prompt, tool definitions, conversation history, tool results, retrieved documents, and scratchpad. Everything the agent "knows" about the task at hand must be re-serialized into tokens on every call. Context engineering is the discipline of deciding **which tokens go into the window, in what order, in what form, at each step**.

Late-2026 frontier models advertise windows from 200K to 1M+ tokens (some 2M). It is tempting to treat this as "infinite memory". It is not, for three independent reasons:

1. **Cost scales with input tokens on every call.** An agent loop of 40 steps that carries 100K tokens of history pays for roughly 4M input tokens, even though the "new" information per step is small.
2. **Latency scales with input tokens.** Prefill is compute-bound; time-to-first-token (TTFT) grows roughly linearly with uncached prompt length, and attention cost grows super-linearly for very long sequences.
3. **Quality degrades with length and clutter.** Models attend unevenly, distractors hurt reasoning, and effective usable context is far below the advertised maximum.

## The Cost Model

A useful first-principles model for a single agent run:

```text
Total cost  ~=  sum over steps t of:
                 (uncached_input_t * P_in)
               + (cached_input_t   * P_cache_read)
               + (cache_write_t    * P_cache_write)
               + (output_t         * P_out)          # includes reasoning tokens

Context at step t:  C_t = S + T + sum_{i<t}(a_i + o_i)
  S = system prompt, T = tool schemas, a_i = assistant msgs, o_i = observations
```

Because `C_t` grows linearly with step count, total input tokens grow **quadratically** in the number of steps when history is never trimmed. That single fact motivates compaction, sub-agent isolation, and observation truncation.

Worked example (illustrative prices): system + tools = 8K tokens, each step adds 3K (tool output + reasoning summary), 50 steps.

| Strategy | Input tokens total | Notes |
|---|---|---|
| Naive append, no cache | ~4.1M | Quadratic growth |
| Naive append, prefix caching (~90% hit) | ~4.1M billed, ~0.4M at full price | Cache read typically ~10% of base price |
| Compaction every 15 steps to 6K summary | ~1.3M | Breaks cache at compaction points |
| Sub-agents for tool-heavy work, main loop sees 500-token results | ~0.6M main + sub-agent cost | Best quality on long tasks, more total calls |

> [!TIP]
> Staff-level framing: the unit of optimization is **cost per successful task**, not cost per call. A compaction step that saves 60% of tokens but drops task success from 82% to 74% is almost always a loss once you price in retries and human escalation. Always evaluate context strategies against an end-to-end success metric.

## Reasoning Tokens Change the Budget

Reasoning models (OpenAI o-series / GPT-5-class thinking modes, Claude extended thinking, Gemini thinking) spend hidden or summarized "thinking" tokens billed as output. Two implications for context engineering:

- **Output dominates cost** for hard steps. Trimming input by 20K tokens may matter less than capping reasoning effort on easy steps (route easy steps to low effort or a smaller model).
- **Thinking blocks and history.** Some APIs require prior thinking blocks to be passed back unmodified during tool-use loops (e.g., Anthropic's extended thinking with tool use requires returning the thinking blocks for the current assistant turn), while others strip or encrypt prior reasoning. Read provider docs: mutating or dropping these incorrectly can cause errors or degrade reasoning continuity.

## Context Rot and Lost-in-the-Middle

**Lost in the middle** (Liu et al., 2023) showed that on multi-document QA, accuracy is highest when the relevant document is at the beginning or end of the context and drops markedly when it is in the middle: a U-shaped curve. Newer models have flattened this curve on simple needle-in-a-haystack (NIAH) tests, but NIAH is a weak test: it requires lexical match of a single fact.

**Context rot** is the broader, 2025-popularized observation (e.g., Chroma's technical report on context rot, and benchmarks such as RULER, NoLiMa, LongBench v2, Michelangelo-style latent structure queries) that performance degrades as input length grows *even when the task difficulty is held constant*, and degrades faster when:

- The needle and question share low lexical overlap (requires semantic inference, not string matching).
- **Distractors** are present: plausible-but-wrong passages are far more damaging than random filler.
- The task requires aggregating or reasoning over many scattered facts (multi-hop, counting, tracking state changes).
- The haystack is coherent text similar to the needle (topic similarity makes discrimination harder).

Mechanistic intuition:

- Softmax attention distributes a finite probability mass over all positions. More tokens means more competitors for attention; relevant signals get diluted.
- Positional encodings (RoPE with scaling such as YaRN / NTK) extrapolated beyond typical training lengths behave less reliably; most training data is short, so long-range attention patterns are under-trained.
- Primacy (attention sinks on early tokens) and recency biases are learned artifacts that produce the U-curve.

```text
Accuracy
  ^
  |\                                  /
  | \                               /
  |  \____                    ____/
  |       \__________________/
  +-------------------------------------> position of relevant info
   start            middle             end
```

> [!WARNING]
> Production pitfall: teams validate an agent on short demo tasks, then deploy to long sessions where the context reaches 150K+ tokens of accumulated tool output. Quality silently drops: the agent "forgets" constraints stated early, repeats completed actions, or follows instructions found in stale tool output. Always run evals at the *p95 context length* your production traffic reaches, not at the median.

## Effective Context vs Advertised Context

Treat effective context as a measured property per model per task family. A practical approach:

1. Build a synthetic eval from your own domain: insert the critical fact(s) at varying depths into realistic (not random) distractor content.
2. Measure accuracy at 8K, 32K, 64K, 128K, and up.
3. Define your *operating budget* as the length where accuracy stays within ~2-3 points of the short-context baseline.

Many teams find that for multi-hop reasoning tasks, the operating budget is 20-40% of the advertised window.

## Where to Put What: Position Heuristics

| Content | Recommended position | Reason |
|---|---|---|
| Stable instructions, persona, policies | Start (system) | Primacy + cacheable prefix |
| Tool definitions | Start, right after system | Stable, cacheable; many APIs place them before system anyway |
| Long reference documents | Before the question | Anthropic and others report better results with documents first, query last |
| The current question / task | End | Recency, and keeps the cacheable prefix stable |
| Critical constraints for long sessions | Restate near end (e.g., in a reminder block) | Counters drift in long contexts |
| Volatile data (timestamps, user-specific values) | As late as possible | Avoid invalidating the cache prefix |

> [!TIP]
> "Restate key constraints near the end" conflicts with "keep the prefix stable" only if you restate them inside the prefix. Put a short, deterministic reminder block at the tail of the context (after history). Claude Code-style systems do exactly this with system reminders injected into recent turns.

# Context Engineering Strategies: Write, Select, Compress, Isolate

## The Four-Strategy Framework

A widely used taxonomy (popularized by LangChain's context engineering writeups, building on Anthropic's and Cognition's posts) groups techniques into four buckets:

| Strategy | Question it answers | Examples |
|---|---|---|
| **Write** | Where do I persist information outside the window? | Scratchpads, todo files, memory stores, state objects, files on disk |
| **Select** | What do I pull into the window now? | RAG, memory retrieval, tool selection, few-shot selection |
| **Compress** | How do I keep the same information in fewer tokens? | Summarization, compaction, observation trimming, structured extraction |
| **Isolate** | How do I keep unrelated information out of a given window? | Sub-agents, sandboxes, state fields hidden from the LLM, multi-agent splits |

The mental model: the context window is a **CPU cache**, external storage is **RAM/disk**, and context engineering is the **memory management unit** deciding what to page in and out. MemGPT made this analogy explicit.

## Write: Externalizing State

Agents should write intermediate state somewhere durable rather than relying on it surviving in history:

- **Scratchpads / plan files.** A `todo.md` or `PLAN.md` the agent rewrites as it progresses. Manus described rewriting a todo list at the end of the context each step so the global plan stays in the recency window: "recitation" to manipulate attention.
- **Structured state.** In LangGraph, the graph state is a typed object; only some fields are rendered into the prompt. In Temporal-based agents, workflow state is durable by construction.
- **File system as memory.** Coding agents (Claude Code, Codex CLI, Cursor agents) treat the repo and notes files as unbounded, persistent, agent-operable context. Large tool outputs are written to files and only a path + summary enters the context.

```python
# Pattern: offload large observations to a file store, keep a handle in context
import hashlib, json, pathlib

ARTIFACTS = pathlib.Path("/workspace/.artifacts")
MAX_INLINE_TOKENS = 1500

def record_observation(tool_name: str, output: str, count_tokens) -> str:
    n = count_tokens(output)
    if n <= MAX_INLINE_TOKENS:
        return output
    digest = hashlib.sha256(output.encode()).hexdigest()[:12]
    path = ARTIFACTS / f"{tool_name}-{digest}.txt"
    path.write_text(output)
    head = output[:2000]
    return json.dumps({
        "truncated": True,
        "tokens": n,
        "artifact_path": str(path),
        "preview": head,
        "hint": "Use read_file with offset/limit or grep to inspect more.",
    })
```

> [!TIP]
> Offloading is **restorable compression**: nothing is lost, because the agent can re-read the file. Prefer restorable compression (drop content but keep a pointer: URL, file path, doc ID) over lossy summarization whenever the agent has a tool to re-fetch.

## Select: Pulling the Right Tokens In

Selection applies to more than documents:

- **Memories**: retrieve relevant user facts / past episodes by embedding similarity, recency, and importance.
- **Tools**: with 100+ tools (common with many MCP servers connected), tool schemas alone can consume 20-60K tokens and confuse selection. Use tool retrieval (embed tool descriptions, select top-k per step), hierarchical toolsets, or deferred tool loading where the provider supports it (e.g., tool search features that load schemas on demand).
- **Few-shot examples**: dynamically select examples similar to the current input (kNN few-shot) rather than a static set.
- **Instructions**: load skill/procedure files only when relevant (the "skills" pattern in Claude Agent SDK / Claude Code: a short description is always in context, full instructions are read on demand). This is *progressive disclosure*.

> [!WARNING]
> Dynamically changing the tool list mid-session invalidates the prompt cache (tools are usually at the front of the prefix) and can confuse the model when earlier turns reference tools that no longer exist. Manus reported preferring to *mask* tool availability via constrained decoding / logit masking rather than removing definitions. If you must vary tools, do it at session boundaries or with provider-supported deferred loading.

## Compress: Fewer Tokens, Same Signal

Compression techniques, ordered from cheapest/safest to most lossy:

1. **Format compression**: strip HTML to Markdown, drop boilerplate, minify JSON, remove null fields, project only needed columns from SQL results.
2. **Observation truncation / masking**: keep the last N tool results verbatim, replace older ones with stubs ("[output of run_tests at step 12 elided; 340 lines; 3 failures]"). Research from 2025 (e.g., JetBrains' study on SWE-agent-style trajectories) found simple observation masking often matches LLM summarization at lower cost.
3. **Structured extraction**: convert a 10K-token web page into a 300-token JSON of facts relevant to the current goal.
4. **LLM summarization / compaction**: summarize history into a running state document. Most lossy; discussed in depth later.
5. **Token-level prompt compression** (LLMLingua-family): drop low-information tokens using a small LM. Useful for RAG passages; less used for agent history because it harms exact identifiers.

## Isolate: Separate Windows for Separate Concerns

Isolation splits work across multiple context windows:

- **Sub-agents**: the orchestrator delegates "research X" to a sub-agent with its own fresh context; the sub-agent may consume 200K tokens exploring but returns a 1-2K token distilled result. Anthropic's multi-agent research system reported large gains on breadth-first research tasks using this pattern, at significantly higher total token cost (multi-agent runs used many times the tokens of single-agent chat).
- **Sandboxed execution**: code runs in a sandbox; only the final values or printed summary return (e.g., the "code execution with MCP" pattern where the agent writes code that calls tools and filters data in the sandbox, so raw intermediate data never enters the model context).
- **State fields hidden from the LLM**: keep raw data in the runtime state, expose only derived fields.

Trade-offs:

| Dimension | Single agent, long context | Orchestrator + sub-agents |
|---|---|---|
| Context clutter | High | Low per window |
| Total tokens | Lower | Higher (often 3-15x) |
| Coherence of decisions | High (one mind sees everything) | Risk of conflicting assumptions between sub-agents |
| Parallelism | Sequential | Parallel sub-tasks |
| Best for | Tightly coupled tasks (coding a single feature) | Breadth-first, separable tasks (research, multi-source analysis) |
| Debuggability | One trace | Distributed traces needed |

> [!TIP]
> Cognition's "Don't build multi-agents" argument and Anthropic's multi-agent research success are compatible: isolation works when sub-tasks are **read-heavy and separable**, and fails when sub-agents make **write decisions that implicitly depend on each other** (e.g., two sub-agents each building half a UI with different style assumptions). Rule of thumb: parallelize reading, serialize writing.

## Putting It Together: A Context Assembly Pipeline

```text
                +--------------------+
 user turn ---> |  Context Assembler |  (deterministic code, not the LLM)
                +---------+----------+
                          |
   +----------+-----------+-----------+-------------+-------------+
   |          |           |           |             |             |
 static    tool       memory       retrieved    compacted      recent
 prefix    selection  retrieval    documents    history        turns + reminders
 (cached)  (top-k)    (semantic,   (hybrid +    (summary of    (verbatim last N)
                       episodic)    rerank)      older turns)
   |          |           |           |             |             |
   +----------+-----------+-----+-----+-------------+-------------+
                                |
                     token budget allocator
                     (per-section caps, priority-ordered drop)
                                |
                             LLM call
```

```python
# Framework-agnostic sketch of a budgeted context assembler
from dataclasses import dataclass

@dataclass
class Section:
    name: str
    content: str
    priority: int        # lower = more important, dropped last
    max_tokens: int
    cacheable: bool      # part of stable prefix?

def assemble(sections: list[Section], budget: int, count) -> str:
    # 1. Clip each section to its own cap
    for s in sections:
        if count(s.content) > s.max_tokens:
            s.content = clip_section(s, s.max_tokens)   # section-specific clipping
    # 2. Drop lowest-priority sections until under budget
    ordered = sorted(sections, key=lambda s: s.priority)
    kept, used = [], 0
    for s in ordered:
        t = count(s.content)
        if used + t <= budget:
            kept.append(s); used += t
    # 3. Re-order for cache friendliness: cacheable prefix first, in fixed order
    kept.sort(key=lambda s: (not s.cacheable, SECTION_ORDER[s.name]))
    return "\n\n".join(f"<{s.name}>\n{s.content}\n</{s.name}>" for s in kept)
```

> [!WARNING]
> Never let the token budget allocator reorder or mutate the *cacheable prefix* based on per-request data. A single dynamic value (a timestamp, a user name, a randomly ordered set of tools from a dict) in the system prompt makes every request a cache miss.

# Agent Memory Architecture

## Taxonomy of Memory

Borrowing from cognitive science (and the CoALA framework: Cognitive Architectures for Language Agents, Sumers et al.), agent memory divides into:

| Memory type | Human analogy | Agent implementation | Lifetime |
|---|---|---|---|
| Working memory | What you are holding in mind | The context window + scratchpad | One call / one session |
| Episodic | "I remember the time when..." | Logs of past interactions, trajectories, outcomes | Long-term |
| Semantic | Facts you know | User profile facts, entity facts, domain knowledge base | Long-term |
| Procedural | How to ride a bike | System prompt rules, learned skills/playbooks, tool code, model weights | Long-term |

A second axis is **who writes** the memory:

- **Hot path (in-loop)**: the agent decides to save a memory via a tool call during the conversation (e.g., `memory.save(...)`). Immediate, but adds latency and distracts the agent.
- **Background (out-of-loop)**: a separate process reflects over transcripts after or between sessions and writes memories. No latency impact, better quality (can use a stronger model and see the whole session), but memories become available later.

## Working Memory and Scratchpads

Working memory is everything the model can attend to right now. Its design questions:

- **What structure?** Raw message list vs. structured state rendered to text. Structured rendering (sections with headers / XML tags) helps the model locate information.
- **Scratchpad semantics.** A scratchpad is model-writable working memory that persists across steps but is not necessarily shown to the user: plans, hypotheses, partial results, todo lists.

```python
# Scratchpad as a tool the agent controls (framework-agnostic)
SCRATCHPAD_TOOL = {
    "name": "update_scratchpad",
    "description": (
        "Overwrite your working notes. Keep: current plan with checkboxes, "
        "key findings with sources, open questions, decisions made and why. "
        "Max ~800 tokens. This is re-shown to you at the end of every turn."
    ),
    "input_schema": {
        "type": "object",
        "properties": {"content": {"type": "string"}},
        "required": ["content"],
    },
}
```

Rendering the scratchpad **at the tail** of each request (not in the system prompt) gives recitation benefits without breaking the cache prefix.

> [!TIP]
> Scratchpads double as compaction seeds. If the agent maintains a high-quality scratchpad, compaction becomes "keep system prompt + scratchpad + last N turns", which is cheap and far less lossy than summarizing a raw transcript after the fact.

## Long-Term Memory: Episodic

Episodic memory stores *what happened*: an interaction, its context, the actions taken, and the outcome. Uses:

- **Personalization**: "Last time we spoke, you were debugging the payments migration."
- **Experience replay / case-based reasoning**: retrieve past successful trajectories for similar tasks as few-shot exemplars.
- **Failure avoidance**: retrieve past failures ("this API returns 429 if called more than 5 times/sec").

Schema example:

```python
from pydantic import BaseModel
from datetime import datetime

class Episode(BaseModel):
    episode_id: str
    tenant_id: str
    user_id: str
    started_at: datetime
    task_summary: str            # 1-2 sentences, embedded for retrieval
    actions_digest: list[str]    # key steps
    outcome: str                 # "success" | "failure" | "abandoned"
    lessons: list[str]           # reflections, e.g. from a Reflexion-style pass
    importance: float            # 0..1, LLM- or heuristic-scored
    embedding: list[float] | None = None
    source_trace_id: str         # link to full trace for audit
```

The Generative Agents paper (Park et al., 2023) introduced a widely copied retrieval score:

```text
score(m) = a * recency(m) + b * importance(m) + c * relevance(m, query)
recency(m)   = decay ** hours_since_last_access(m)      e.g. decay = 0.995
importance   = LLM-rated 1..10 at write time, normalized
relevance    = cosine(embed(m), embed(query))
```

## Long-Term Memory: Semantic

Semantic memory stores *facts*: user preferences, entity attributes, domain knowledge. Two representation choices:

| Representation | Example | Pros | Cons |
|---|---|---|---|
| **Profile document** (single JSON/Markdown per user) | `{"diet": "vegetarian", "timezone": "IST"}` | Always fully loaded, easy to read and update, no retrieval needed | Bounded size, schema design needed, update conflicts |
| **Collection of facts** (many small records) | "User prefers pytest over unittest (2026-03-02)" | Unbounded, granular provenance, searchable | Needs retrieval, dedup, contradiction handling |
| **Knowledge graph** | `(user)-[PREFERS]->(pytest)` | Multi-hop queries, explicit relations, temporal edges | Extraction cost, schema drift, more infra |

Frameworks: LangGraph's long-term memory store (namespaced key-value with optional semantic search) and LangMem; Mem0 (extract-then-update pipeline with ADD/UPDATE/DELETE/NOOP operations, plus a graph variant); Zep / Graphiti (temporal knowledge graph with bi-temporal edges: when a fact was true vs. when it was recorded); Letta (MemGPT successor) with memory blocks; OpenAI and Anthropic consumer products with user-visible memory; Claude's memory tool (a file-directory-based memory the agent reads/writes via tool calls).

## Long-Term Memory: Procedural

Procedural memory is *how to act*. In agents it lives in:

- **System prompt / instructions**, which can be updated by a reflection process (prompt optimization: e.g., LangMem's prompt optimizer, DSPy optimizers like MIPROv2/GEPA run offline).
- **Skills / playbooks**: reusable Markdown + script bundles loaded on demand (Claude Agent Skills). Agents can author new skills after solving a task: Voyager-style skill libraries.
- **Model weights**: fine-tuning (SFT, RLVR/GRPO on verified trajectories) bakes procedures in. Slowest and most expensive to update, but zero context cost.

> [!WARNING]
> Self-modifying procedural memory is a security surface. If an agent can rewrite its own instructions based on conversation content, a prompt injection in one session can become a **persistent** backdoor across all future sessions ("memory poisoning"). Require human review or strict validation for procedural memory writes, and scope them per user/tenant.

## MemGPT / Letta-Style Hierarchical Memory

MemGPT (Packer et al., 2023) framed the LLM as an operating system managing virtual memory:

```text
+------------------------------------------------------------+
|                    MAIN CONTEXT (in window)                |
|  +-------------------+  +-------------------------------+  |
|  | System instructions|  | Core memory blocks (editable)|  |
|  | (read-only)        |  |  - persona: "I am ..."       |  |
|  +-------------------+  |  - human:   "User is ..."     |  |
|                         +-------------------------------+  |
|  +------------------------------------------------------+  |
|  | FIFO message queue (recent messages) + recursive     |  |
|  | summary of evicted messages                          |  |
|  +------------------------------------------------------+  |
+--------------------------|---------------------------------+
                           | function calls (self-directed paging)
          +----------------+-----------------+
          v                                  v
+---------------------+          +--------------------------+
| RECALL STORAGE      |          | ARCHIVAL STORAGE         |
| full message history|          | vector DB of arbitrary   |
| (searchable by text |          | long-term facts/docs     |
|  and date)          |          | (archival_memory_insert/ |
| conversation_search |          |  archival_memory_search) |
+---------------------+          +--------------------------+
```

Key mechanics:

- **Core memory** is a small set of labeled, size-limited text blocks always in context. The agent edits them via tools (in MemGPT: `core_memory_append`, `core_memory_replace`; Letta has evolved its tool set and memory block APIs, so check current docs).
- **Memory pressure warnings**: when the context nears its limit, the system injects a warning, prompting the agent to save important information before eviction.
- **Eviction + recursive summarization**: old messages are flushed from the queue into recall storage, and a running summary is updated.
- **Self-directed retrieval**: the agent decides when to search recall/archival memory, paging information back in.
- **Heartbeats / chained function calls**: the agent can request another step after a tool call, enabling multi-step memory operations without user input.

Letta later added "sleep-time agents": background agents that reorganize memory asynchronously while the primary agent is idle, the hot-path vs background split.

| Aspect | MemGPT-style self-managed memory | Externally managed memory pipeline |
|---|---|---|
| Who decides what to remember | The agent itself via tool calls | Deterministic code + background LLM extraction |
| Latency | Adds tool calls in the hot path | None in hot path |
| Transparency | Memory edits are visible actions in the trace | Happens out of band; needs its own observability |
| Failure mode | Agent forgets to save, or saves noise | Extractor misses context the agent understood |
| Best for | Long-lived companion/assistant agents | Enterprise apps needing predictable behavior |

> [!TIP]
> Hybrid is the production default in 2026: a small always-in-context core profile (MemGPT-style blocks), background extraction for facts and episodes, and an explicit `search_memory` tool so the agent can page in more when needed. Do not make the agent's task performance depend on it remembering to call `save_memory`.

## Memory Scoping and Namespaces

Every memory must have an explicit scope; most memory bugs are scope bugs.

```text
namespace = (tenant_id, scope, owner_id, [agent_id], [topic])

scope examples:
  ("acme", "user",    "u_123")              personal preferences
  ("acme", "team",    "payments")           shared team conventions
  ("acme", "org",     "*")                  org-wide policies (admin-written)
  ("acme", "agent",   "support-bot", "faq") agent-learned procedures
  ("acme", "session", "s_987")              ephemeral, TTL'd
```

> [!WARNING]
> Cross-user memory leakage is the most damaging memory bug: an agent retrieves user A's memory while serving user B because the vector search filter used `tenant_id` but not `user_id`, or because a "team" memory was extracted from a private DM. Enforce scope filters in the storage layer (mandatory filter injection), never by asking the LLM to "only use this user's memories".


# Memory Policies: Write, Read, Update, Forget

## The Memory Lifecycle

Memory is a data pipeline with a lifecycle, and each stage needs an explicit policy:

```text
 transcript / events
        |
   [1] WRITE policy  -- what is worth remembering? (extraction, salience)
        |
   [2] CONSOLIDATE   -- dedupe, merge, resolve conflicts against existing memory
        |
   [3] STORE         -- scoped namespace, embeddings, metadata, provenance
        |
   [4] READ policy   -- when to retrieve, how many, how to rank, how to render
        |
   [5] UPDATE        -- reinforce on use, correct on contradiction
        |
   [6] FORGET        -- TTL, decay, user deletion, compliance erasure
```

## Write Policy: What Is Worth Remembering

Bad write policies are the root cause of most "creepy" or "dumb" memory behaviors. Criteria:

- **Durability**: Will this still be true and useful in a week? "User is vegetarian" yes; "User is hungry" no.
- **Actionability**: Will it change future agent behavior?
- **Explicitness**: Did the user state it, or did the model infer it? Store inferred facts with lower confidence, or not at all for sensitive categories.
- **Sensitivity**: Health, finances, political views, credentials. Many products exclude these by default unless the user explicitly asks to remember them.
- **Scope**: personal vs team vs org.

```python
EXTRACTION_PROMPT = """You maintain long-term memory for an assistant.
From the conversation below, extract facts worth remembering for FUTURE sessions.

Rules:
- Only durable facts (preferences, stable attributes, ongoing projects, explicit instructions).
- Skip transient states, small talk, and anything the user asked not to remember.
- Never store secrets, credentials, or payment data.
- Mark source as "explicit" if the user stated it directly, "inferred" otherwise.
- Each fact must be self-contained (resolve pronouns, include dates in ISO format).

Return JSON: {"facts": [{"text": str, "category": str, "source": "explicit"|"inferred",
               "confidence": float, "sensitive": bool}]}
"""
```

## Consolidation and Conflict Resolution

When a new candidate fact arrives, compare it against similar existing memories and decide an operation. Mem0 popularized the four-operation scheme:

| Operation | When | Example |
|---|---|---|
| ADD | No semantically similar memory exists | New: "Uses Postgres 16" |
| UPDATE | Same subject, richer or newer information | "Likes Python" to "Likes Python, especially FastAPI" |
| DELETE (or invalidate) | New fact contradicts old | "Lives in Pune" contradicted by "Moved to Bangalore in Oct 2026" |
| NOOP | Duplicate or irrelevant | Restatement of an existing fact |

```python
# Framework-agnostic consolidation step
def consolidate(candidate, store, llm, k=5):
    neighbors = store.search(candidate.text, namespace=candidate.ns, k=k, min_score=0.75)
    decision = llm.structured(
        prompt=CONSOLIDATE_PROMPT.format(new=candidate.text,
                                         existing=[(n.id, n.text, n.updated_at) for n in neighbors]),
        schema={"op": "ADD|UPDATE|DELETE|NOOP", "target_id": "str|null", "merged_text": "str|null"},
    )
    if decision.op == "ADD":
        store.put(candidate)
    elif decision.op == "UPDATE":
        store.update(decision.target_id, text=decision.merged_text, provenance_append=candidate.source)
    elif decision.op == "DELETE":
        store.invalidate(decision.target_id, invalid_at=candidate.observed_at,
                         superseded_by=store.put(candidate))
    # NOOP: optionally bump last_confirmed_at on the matched memory
```

Conflict resolution principles:

1. **Prefer invalidation over deletion.** Bi-temporal modeling (Graphiti/Zep style) records `valid_from`, `valid_to` (world time) and `created_at`, `expired_at` (system time). You can then answer "where did the user live in 2025?" and audit why the agent believed something.
2. **Source precedence.** Explicit user statement > admin-entered data > system-of-record sync > inferred by LLM. A later *inferred* fact should not overwrite an earlier *explicit* one without confirmation.
3. **Recency is a tiebreaker, not a rule.** "I'm vegetarian" (explicit, January) vs agent observing user order chicken (inferred, March) should trigger a clarification, not a silent overwrite.
4. **Ask when stakes are high.** For consequential facts (shipping address, medication), surface the conflict to the user.
5. **Systems of record win.** If the CRM says the customer's plan is Enterprise, memory must not override it. Memory caches facts; it is not the source of truth for business data.

> [!WARNING]
> LLM-based consolidation is non-deterministic and can cascade: a bad UPDATE merges two unrelated facts, the merged text then matches more candidates, and errors compound. Keep the raw extracted facts (append-only log) separate from the consolidated view so you can rebuild the view with a better consolidator. Treat consolidated memory like a materialized view over an event log.

## Read Policy: When and What to Retrieve

Options, from simplest to most agentic:

| Read policy | Mechanism | Pros | Cons |
|---|---|---|---|
| Always-load profile | Inject full core profile every turn | Zero retrieval misses, cacheable if stable | Size-bounded |
| Per-turn retrieval | Embed user message, retrieve top-k memories | Automatic | Irrelevant memories inserted; spurious personalization |
| Agent-invoked tool | `search_memory(query)` tool | Agent controls relevance | Agent may not call it when needed |
| Pre-task retrieval | Retrieve once at session/task start | Cheap, stable prefix | Misses topic shifts |

Rendering matters: present memories with provenance and dates so the model can weigh them.

```text
<user_memory>
- [2026-09-14, explicit] Prefers concise answers with code first.
- [2026-10-02, explicit] Works on the payments-service repo (Go, Postgres 16).
- [2026-11-01, inferred, conf=0.6] May be preparing for a staff engineer interview.
</user_memory>
Use these only if relevant to the current request. Do not mention them unprompted.
```

> [!TIP]
> Over-personalization is a real product failure: injecting every retrieved memory leads models to shoehorn irrelevant facts into answers ("Since you're vegetarian, here is a Python sorting algorithm..."). Use a relevance threshold, cap memories at a small k, and instruct the model to use memories only when pertinent. Measure "inappropriate memory use" as an explicit eval dimension.

## Update and Reinforcement

- **Access-based reinforcement**: bump `last_accessed_at` when a memory is retrieved *and used* (cited in the answer), which feeds recency scoring.
- **Confirmation**: when a user's behavior is consistent with an inferred memory, raise confidence; when contradicted, lower it.
- **Reflection**: periodically (sleep-time) synthesize higher-level memories from many low-level ones ("User consistently asks for type hints" from 12 separate episodes), as in Generative Agents' reflection step.

## Forget Policy

Forgetting is required for quality, cost, and compliance:

- **TTL by category**: session memories expire in hours, task context in days, preferences rarely.
- **Decay-based eviction**: memories with low `recency * importance` and no access in N days are archived or dropped.
- **Superseded facts**: invalidated facts are excluded from retrieval but retained for audit (subject to retention policy).
- **User-initiated deletion**: "forget that I told you X" must work, including derived artifacts: embeddings, summaries that contain the fact, graph edges, cached prompts.
- **Compliance erasure (GDPR/DPDP right to erasure)**: requires lineage from source data to every derived memory.

> [!WARNING]
> Deleting a memory record while leaving the fact inside a rolling session summary, a reflection memory, or a fine-tuning dataset is a compliance failure. Maintain **lineage**: every derived memory stores the IDs of its source memories/messages, so deletion can cascade. Summaries derived from deleted data must be regenerated.

# Compaction and Summarization

## Why Compaction Exists

When history approaches the operating budget, you must shrink it. Compaction replaces a span of history with a shorter representation while preserving what future steps need. Claude Code's auto-compact, the Claude API's server-side context management features (context editing to clear old tool results, compaction), OpenAI's conversation state options and Responses API compaction, and LangGraph summarization nodes all implement variations.

## Compaction Strategies

| Strategy | Mechanism | Information loss | Cache impact | Cost |
|---|---|---|---|---|
| Sliding window | Keep last N turns, drop older | High (abrupt) | Breaks prefix each slide unless done in chunks | Free |
| Tool result clearing | Replace old tool outputs with stubs, keep assistant reasoning and calls | Low-medium; restorable if re-fetchable | Breaks at clearing point | Free |
| Rolling summary | Summarize evicted turns into running summary | Medium | Breaks when summary updates | One LLM call per compaction |
| Hierarchical summary | Summaries of summaries (chapter-level) | Medium, better for very long runs | Same | More calls |
| Structured state extraction | Extract into schema: goals, decisions, files touched, open issues | Low for schema fields, high for anything else | Same | One call |
| Restart with handoff | New session seeded with a handoff note + pointers | Depends on note quality | Fresh cache | One call |

## What a Good Compaction Summary Preserves

A compaction prompt should be explicit about what must survive. For coding/ops agents:

```text
Summarize the conversation so far for your own continuation. Preserve EXACTLY:
1. The user's original request and all explicit constraints/preferences (quote them).
2. Decisions made and the reasons (including rejected approaches and why).
3. Current state: files created/modified (paths), commands run that changed state,
   external side effects (tickets filed, emails sent, deployments).
4. Unresolved errors with exact error messages and identifiers.
5. The current plan with completed / in-progress / pending items.
6. Any IDs, URLs, file paths, or values needed to continue (verbatim).
Omit: exploratory output that led nowhere, full file contents (keep paths),
redundant tool output.
```

> [!WARNING]
> Classic compaction failures: (1) **side-effect amnesia**, where the summary omits that an email was already sent, so the agent sends it again; (2) **constraint loss**, where "do not modify the public API" disappears and the agent later breaks it; (3) **identifier corruption**, where the summarizer paraphrases `order_8f3a2c` into "the order". Mitigate with a structured schema, a side-effect ledger kept outside the LLM, and idempotency keys on all side-effecting tools.

## Trigger Policies

- **Threshold-based**: compact when context reaches ~70-85% of the operating budget (not the advertised max), leaving headroom for the next tool result and reasoning.
- **Boundary-based**: compact at natural task boundaries (sub-task completed, plan item checked off), which yields cleaner summaries than mid-thought compaction.
- **Cost-based**: compact when expected remaining steps times current context size exceeds a budget.

```python
def maybe_compact(state, count, budget, llm):
    used = count(state.render())
    if used < 0.75 * budget and not state.at_task_boundary:
        return state
    keep_recent = state.messages[-6:]            # always keep last few turns verbatim
    to_summarize = state.messages[:-6]
    summary = llm.structured(COMPACTION_PROMPT, to_summarize, schema=CompactionSchema)
    state.messages = [system_msg(state.system),
                      user_msg(render_summary(summary, state.side_effect_ledger))] + keep_recent
    state.compactions += 1
    return state
```

> [!TIP]
> Make compaction *evaluable*: log pre- and post-compaction contexts and run an offline probe set ("What files have you modified? What did the user forbid? What's the next step?") against the post-compaction context. Factual recall on these probes is a cheap regression test when you change the compaction prompt or model.

## Summarization for Memory vs Compaction

These are different tasks often conflated:

- **Compaction** optimizes for *continuing the current task*; it is short-lived and goal-specific.
- **Memory summarization** optimizes for *future unknown tasks*; it should be goal-agnostic, factual, and decontextualized.

Using a compaction summary as long-term memory produces memories full of task-specific scaffolding ("next step: run tests again") that pollute future sessions.

# Prompt Caching and KV-Cache Mechanics

## What Is Being Cached

In a transformer decoder, each layer computes Key and Value vectors for every token. During generation, the model reuses previously computed K/V for all earlier tokens (the **KV cache**) and only computes the new token. Prefill (processing the prompt) is the expensive, compute-bound phase; decode is memory-bandwidth-bound.

**Prompt caching** (also called prefix caching or context caching) persists the KV cache for a prompt prefix across requests. If a new request shares an identical token prefix with a cached one, prefill for that prefix is skipped.

KV cache size per token, which explains why caches are evicted quickly:

```text
bytes_per_token = 2 (K and V) * n_layers * n_kv_heads * head_dim * bytes_per_element

Example (70B-class, GQA): 80 layers * 8 kv_heads * 128 dim * 2 * 2 bytes (fp16)
                        = ~327 KB per token
100K-token prefix       = ~32 GB of KV cache
```

This is why providers tier storage (HBM, host RAM, SSD), charge for cache writes, and evict after minutes. Techniques like GQA/MQA, MLA (DeepSeek's multi-head latent attention), KV quantization (FP8), and paged attention (vLLM's PagedAttention) all exist to shrink or manage this memory.

## Prefix Matching Semantics

Cache hits require an **exact token-prefix match** from the start of the prompt. Implications:

- Any change at position `i` invalidates the cache for every token after `i`.
- Order of components matters: the API typically serializes tools, then system, then messages (the exact order varies by provider).
- Self-hosted engines (vLLM automatic prefix caching, SGLang RadixAttention) hash fixed-size token blocks and share them across requests via a radix tree / block hash table, enabling sharing of common prefixes among many concurrent requests.

## Provider Models (as of late 2026; verify current docs)

| Provider | Mechanism | Developer control | Pricing shape |
|---|---|---|---|
| Anthropic (Claude) | Explicit `cache_control` breakpoints on content blocks (up to a small fixed number of breakpoints); default ~5-minute TTL refreshed on hit, optional 1-hour TTL | High: you choose where the prefix ends | Cache write premium over base input; cache reads ~10% of base |
| OpenAI | Automatic prefix caching for prompts above a minimum length (~1024 tokens); optional `prompt_cache_key` to improve routing | Low-medium: structure prompt, set key | Cached input discounted (large discount on newer models) |
| Google Gemini | Implicit caching on newer models plus explicit `CachedContent` objects with configurable TTL | High for explicit caches | Discounted cached tokens plus storage cost per hour for explicit caches |
| Self-hosted (vLLM, SGLang, TensorRT-LLM) | Automatic prefix/radix caching in GPU memory, optional CPU/disk offload (e.g., LMCache) | Full | Your GPU memory and routing |

Anthropic example (Messages API shape):

```python
import anthropic
client = anthropic.Anthropic()

resp = client.messages.create(
    model="claude-sonnet-4-5",   # use your current model id
    max_tokens=2048,
    system=[
        {"type": "text", "text": STATIC_INSTRUCTIONS},
        {"type": "text", "text": LARGE_REFERENCE_DOC,
         "cache_control": {"type": "ephemeral"}},       # breakpoint 1: end of static prefix
    ],
    tools=TOOLS,  # tools precede system in the cached prefix ordering
    messages=history + [{"role": "user", "content": [
        {"type": "text", "text": new_user_turn,
         "cache_control": {"type": "ephemeral"}}       # breakpoint 2: incremental conversation cache
    ]}],
)
u = resp.usage
print(u.cache_creation_input_tokens, u.cache_read_input_tokens, u.input_tokens)
```

## Cache-Friendly Prompt Layout

```text
+------------------------------------------------------+  <- most stable
| Tool definitions (deterministically ordered)          |
| System prompt: role, policies, output format          |
| Static knowledge: docs, schemas, few-shot examples    |
|------------------------------ cache breakpoint -------|
| Session-stable: user profile, core memory blocks      |
|------------------------------ cache breakpoint -------|
| Conversation history (append-only)                    |
|------------------------------ cache breakpoint -------|
| Volatile tail: retrieved docs for this turn,          |
| scratchpad recitation, reminders, current timestamp,  |
| current user message                                  |
+------------------------------------------------------+  <- most volatile
```

Rules:

1. **Append-only history.** Never edit earlier messages in place; never re-serialize with different whitespace or JSON key order. Use deterministic serialization (`json.dumps(obj, sort_keys=True, separators=(",", ":"))`).
2. **No volatile values in the prefix.** Move "Current date: 2026-11-25 20:24:31" to the tail, or round to the day.
3. **Stable tool ordering.** Sort tools by name; do not build them from unordered sets.
4. **Per-turn retrieval goes in the tail**, not the system prompt.
5. **Compaction is a cache reset.** Batch compaction (compact large chunks rarely) rather than sliding by one turn each step.
6. **Keep caches warm.** For bursty workloads, TTL expiry dominates miss rate; Anthropic's 1-hour TTL or periodic cheap keep-alive calls may pay off when traffic gaps exceed 5 minutes (do the math).
7. **Route for affinity.** Self-hosted: use prefix-aware load balancing (route requests with the same prefix hash to the same replica). OpenAI: `prompt_cache_key` per tenant or per conversation.

> [!WARNING]
> A common silent regression: a developer adds "Today is {datetime.now()}" to the system prompt or injects the user's name into the first line. Cache hit rate drops from 85% to near 0, latency and cost jump 3-5x, and no functional test fails. Monitor `cache_read_tokens / total_input_tokens` as a first-class SLO metric with alerts.

## Cache Economics

Break-even for explicit caching (Anthropic-style write premium W relative to base, read price R relative to base):

```text
Without caching: n requests * P tokens * 1.0
With caching:    P * W  +  (n - 1) * P * R        (assuming all hits within TTL)
Example W = 1.25, R = 0.1:  caching wins once n >= 2
                         10 requests: 1.25 + 0.9 = 2.15 vs 10  (78% saving)
```

Latency: cached prefixes reduce TTFT dramatically for long prompts (often by more than half for 100K-token prefixes), which matters for interactive agents more than cost.

> [!TIP]
> Prompt caching changes architecture decisions. With cheap cached reads, "stuff a stable 150K-token knowledge base into a cached prefix" can beat RAG on quality and engineering cost for small, slowly changing corpora (a pattern sometimes called CAG, cache-augmented generation). It loses when the corpus is large, changes often, needs ACLs per user, or when context rot dominates. Evaluate both; don't assume RAG.

## KV-Cache-Aware Agent Design

Manus's widely cited lessons for agent loops are KV-cache-centric: keep the prefix stable, make context append-only, mask tools instead of removing them, use the filesystem as externalized memory, and recite goals at the tail. Additional patterns:

- **Fork-friendly sub-agents**: sub-agents that share the orchestrator's system prompt and tool block get cache hits on that shared prefix.
- **Parallel sampling**: best-of-n or tree search over a shared prefix reuses the same cache (SGLang's radix cache excels at this).
- **Avoid reordering retrieved documents across turns** if they are part of a cached segment.

# RAG Fundamentals

## The Retrieval Problem

Retrieval-Augmented Generation grounds a model's output in an external corpus at inference time. RAG addresses: knowledge cutoff, private data, verifiability (citations), and reducing hallucination. The canonical pipeline:

```text
INGESTION (offline / streaming)
 sources -> connectors -> parse (PDF/HTML/Office/OCR) -> clean -> chunk
        -> enrich (metadata, titles, summaries, ACLs) -> embed -> index (dense + sparse)

QUERY (online)
 user query -> [rewrite/expand] -> retrieve (hybrid) -> fuse -> rerank -> filter (ACL, freshness)
           -> pack context (dedupe, order, budget) -> generate with citations -> verify
```

Retrieval quality bounds generation quality: if the right passage is not in the context, the best model cannot answer faithfully. Most RAG failures in production are **retrieval and parsing failures**, not generation failures.

## Parsing: The Unglamorous Foundation

- PDFs: layout-aware parsing (tables, multi-column, headers/footers). Options include vision-language-model-based parsing (rendering pages as images and asking a VLM to transcribe to Markdown), layout models (e.g., Docling, Unstructured, LlamaParse-class services), and OCR for scans.
- Tables: preserve as Markdown or HTML-like structure, or convert to row-wise sentences ("Q3 revenue for EMEA was $12.4M"); chunking through the middle of a table destroys meaning.
- Visual retrieval: ColPali-style models embed page *images* directly using late interaction, bypassing text extraction for visually rich documents.

> [!WARNING]
> Garbage-in: a parser that drops table headers, merges two columns into interleaved text, or loses footnotes produces chunks that embed fine and retrieve fine but are semantically wrong. Always sample-inspect parsed output per document type before tuning anything downstream.

## Chunking

Chunking trades **retrieval precision** (small chunks match queries tightly) against **context sufficiency** (large chunks contain enough to answer).

| Strategy | How | Pros | Cons |
|---|---|---|---|
| Fixed-size token windows with overlap | e.g., 512 tokens, 64 overlap | Simple, predictable | Splits mid-sentence/section |
| Recursive / structural | Split by headings, then paragraphs, then sentences | Respects document structure | Variable sizes |
| Semantic chunking | Split where embedding similarity between adjacent sentences drops | Topic-coherent chunks | Costly, sensitive to threshold |
| Document-specific | Code by function/class (AST), legal by clause, chat by thread | Best fidelity | Per-format engineering |
| Small-to-big / parent-child | Index small chunks; return parent section | Precise match + sufficient context | More storage, dedup needed |
| Late chunking | Embed whole document with a long-context embedder, then pool token embeddings per chunk | Chunk embeddings carry document context | Needs long-context embedding model |
| Contextual retrieval | Prepend an LLM-generated 50-100 token context ("This chunk is from ACME's 2025 10-K, section on risk...") to each chunk before embedding and BM25 indexing | Anthropic reported substantial reductions in retrieval failures, larger with reranking | Ingestion LLM cost (mitigated by prompt caching the full document) |

```python
# Contextual retrieval at ingestion (framework-agnostic sketch)
CONTEXT_PROMPT = """<document>{doc}</document>
Here is a chunk from the document:
<chunk>{chunk}</chunk>
Write 1-2 sentences situating this chunk within the overall document to improve
search retrieval. Answer only with the context."""

def contextualize(doc_text, chunks, llm):
    out = []
    for c in chunks:
        # doc_text is identical across calls -> put it in a cached prefix
        ctx = llm.complete(CONTEXT_PROMPT.format(doc=doc_text, chunk=c.text), cache_prefix=True)
        out.append(c.with_text(f"{ctx}\n\n{c.text}"))
    return out
```

> [!TIP]
> There is no universally optimal chunk size. Typical starting points: 256-512 tokens for factoid QA, 512-1024 for explanatory content, structure-aligned for code and legal. Pick by measuring retrieval recall@k on a labeled query set for *your* corpus, and remember the answer changes when you add a reranker (rerankers tolerate larger candidate chunks).

## Embeddings

A bi-encoder maps text to a dense vector such that semantic similarity corresponds to geometric closeness (cosine / dot product). Key properties when choosing a model:

- **Domain and language fit**: check MTEB/MMTEB retrieval scores, but validate on your own data; leaderboard ranks often do not transfer.
- **Asymmetric query/document encoding**: many models need instruction prefixes (e.g., "query: " / "passage: " or task instructions). Forgetting them silently degrades recall.
- **Dimensions and Matryoshka (MRL)**: Matryoshka-trained models let you truncate vectors (e.g., 3072 to 256 dims) with modest quality loss, cutting storage and latency. Use truncated vectors for first-pass ANN and full vectors for re-scoring.
- **Max input length**: chunks longer than the model's limit are silently truncated.
- **Quantization**: int8 or binary embeddings cut memory 4-32x; binary + rescoring with float vectors is a strong cost play.

> [!WARNING]
> Changing the embedding model requires **re-embedding the entire corpus**: vectors from different models live in incompatible spaces. Version embedding indices (`index_v7_model-x_dim1024`), run dual-write during migration, and never mix vectors from different models in one index. Also pin the model version: an API provider silently updating a model alias breaks similarity between old and new vectors.

## Approximate Nearest Neighbor Indexes

Exact kNN over N vectors of dimension d costs O(N*d) per query; at 100M vectors this is too slow. ANN indexes trade a little recall for orders-of-magnitude speedups.

### HNSW (Hierarchical Navigable Small World)

```text
Layer 2:   o-----------------o                 (few nodes, long-range links)
           |                 |
Layer 1:   o-----o-----o-----o-----o           (more nodes)
           |     |     |     |     |
Layer 0:   o-o-o-o-o-o-o-o-o-o-o-o-o-o-o-o     (all nodes, short-range links)

Search: enter at top layer, greedy-walk to nearest neighbor, descend, repeat;
at layer 0 do a beam search of width ef_search.
```

- Parameters: `M` (max neighbors per node; memory and recall), `ef_construction` (build quality), `ef_search` (query-time recall/latency knob).
- Pros: excellent recall/latency, supports incremental inserts.
- Cons: memory-hungry (full vectors + graph in RAM), deletes are awkward (tombstones, degrade graph), heavy filtering can break graph connectivity.

### IVF (Inverted File Index)

- Cluster vectors with k-means into `nlist` centroids. At query time, probe the `nprobe` nearest centroids and scan their lists.
- Pros: lower memory than HNSW, simple, good with compression, fast to build at scale.
- Cons: recall depends on `nprobe`; clusters drift as data changes (periodic retraining needed).

### PQ (Product Quantization)

- Split each vector into m sub-vectors; quantize each to one of 256 centroids (1 byte). A 768-dim float32 vector (3072 bytes) becomes e.g. 96 bytes.
- Distances computed via lookup tables (asymmetric distance computation).
- Typically combined: **IVF-PQ** (FAISS), or HNSW over PQ-compressed vectors, with **re-ranking** using full-precision vectors for the top candidates.

### DiskANN and Others

- DiskANN / Vamana: graph index on SSD with compressed vectors in RAM; billion-scale on a single node. Used in several managed services and databases.
- ScaNN (Google): anisotropic quantization, strong on recall/throughput.

| Index | Memory | Build speed | Query latency | Updates | Filtering | Typical use |
|---|---|---|---|---|---|---|
| Flat (exact) | High | None | Slow at scale | Trivial | Easy | Under ~100K vectors, ground truth for evals |
| HNSW | High | Medium | Very low | Good inserts, weak deletes | Needs filter-aware traversal | Default for under ~50M vectors in RAM |
| IVF-Flat | Medium-high | Fast | Low | Retrain centroids periodically | Easy per list | Large, batch-updated corpora |
| IVF-PQ | Low | Fast | Low (with rerank) | Same as IVF | Easy | 100M-1B+ vectors, cost-sensitive |
| DiskANN | Low RAM, SSD | Slow | Low | Supported in fresh variants | Supported in filtered variants | Billion-scale, single node |

> [!WARNING]
> **Filtered ANN pitfall**: post-filtering (retrieve top-k then apply `tenant_id = X`) can return zero or few results when the filter is selective: the top 100 global neighbors may all belong to other tenants. Pre-filtering with brute force is accurate but slow. Use engines with filter-aware graph traversal (e.g., ACORN-style filtered HNSW, Qdrant's payload-index-aware HNSW, Weaviate/pgvector iterative scans), or partition indexes per tenant. Always test recall under your real filter selectivity.

> [!TIP]
> Vector database choice is rarely the bottleneck. pgvector (with HNSW and iterative index scans) inside an existing Postgres often wins on operational simplicity, transactional consistency with ACL tables, and joins up to tens of millions of vectors. Dedicated engines (Qdrant, Weaviate, Milvus, Pinecone, Vespa, Elasticsearch/OpenSearch, Turbopuffer) win at larger scale, with heavy hybrid/filtering requirements, or serverless economics. Choose by filtering, hybrid support, update patterns, and ops model, not by ANN benchmark charts.

