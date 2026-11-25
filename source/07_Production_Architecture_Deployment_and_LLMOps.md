[TOC]

# Reference Agent Platform Architecture

## Why Agents Need a Platform, Not a Script

A prototype agent is a loop: call a model, parse tool calls, execute tools, append results, repeat until the model stops. That loop fits in sixty lines of Python and works beautifully on a laptop. In production the same loop must survive provider outages, enforce per-tenant budgets, resume after a pod is evicted mid-run, stream partial output to a browser, keep secrets away from the model, emit traces an on-call engineer can read at 3 a.m., and be upgraded without breaking in-flight sessions. None of those concerns live in the loop itself. They live in the platform around it.

The mental model that scales is to treat the **agent loop as a stateful, non-deterministic, long-running workflow whose steps are expensive remote calls**. Every property of that sentence drives an architectural decision:

- **Stateful** means you need durable state (conversation, scratchpad, tool results) that outlives any single process.
- **Non-deterministic** means you cannot rely on replaying a run to reproduce a bug; you must record what happened.
- **Long-running** means HTTP request/response is the wrong default transport for anything beyond a few seconds.
- **Expensive remote calls** means caching, routing, batching and budgeting have first-order cost and latency impact.

## The Layered Reference Architecture

```
                 +---------------------------------------------------+
 Clients  ---->  |  Edge / API Gateway (authn, WAF, rate limit, SSE) |
 (web, mobile,   +-------------------------+-------------------------+
  Slack, A2A)                              |
                                           v
                 +---------------------------------------------------+
                 |  Session / Conversation Service                   |
                 |  (session ids, tenancy, idempotency keys)         |
                 +-------------------------+-------------------------+
                                           |
                    sync (short)           |     async (long)
                 +-------------+           |   +--------------------+
                 | Inline      |<----------+-->| Durable Orchestrator|
                 | Agent Runner|               | (Temporal / queue + |
                 +------+------+               |  workers / LangGraph|
                        |                      |  checkpointer)      |
                        |                      +---------+----------+
                        v                                v
          +-----------------------------------------------------------+
          |                 Agent Runtime (the loop)                   |
          |  planner / policy  |  context builder  |  guardrails       |
          +-----+-------------------+-------------------+-------------+
                |                   |                   |
                v                   v                   v
     +-----------------+  +------------------+  +--------------------+
     | LLM Gateway /   |  | Tool Layer       |  | Memory & State     |
     | Model Router    |  | (MCP servers,    |  | - session store    |
     | - quotas        |  |  internal APIs,  |  | - vector / hybrid  |
     | - fallbacks     |  |  sandboxes,      |  | - KV / Redis       |
     | - caching       |  |  computer use)   |  | - object store     |
     +--------+--------+  +--------+---------+  +---------+----------+
              |                    |                      |
              v                    v                      v
   Providers (OpenAI, Anthropic,  Downstream systems     Postgres, pgvector,
   Google, Bedrock, self-hosted   (CRM, DBs, SaaS)       Redis, S3/GCS
   vLLM/SGLang)
                                           |
          +--------------------------------v--------------------------+
          | Observability: OTel traces (GenAI semconv), metrics, logs, |
          | eval pipelines, cost ledger, trajectory warehouse          |
          +-----------------------------------------------------------+
```

Each box has a clear contract.

### Edge / API Gateway

Terminates TLS, authenticates the caller (OIDC/JWT, API keys, mTLS for service-to-service and A2A peers), applies coarse rate limits, and holds long-lived connections for Server-Sent Events or WebSockets. It must be configured for long idle timeouts — many default load balancers kill connections at 60 seconds, which silently truncates streaming responses from reasoning models that think for 90 seconds before emitting the first visible token.

### Session Service

Owns the mapping from user/tenant to session, issues **idempotency keys** for every user turn, and is the source of truth for "which run is currently active for this conversation." It prevents the classic double-submit bug where a user hits Enter twice and two agent runs race to write to the same conversation.

### Orchestrator

Decides how a run executes. Short interactive turns may run inline in the request-handling process. Anything that can exceed a few tens of seconds, needs human approval, or has side effects that must not be duplicated goes to a **durable orchestrator**: Temporal, a queue-plus-worker system, or a graph runtime with a persistent checkpointer (LangGraph with a Postgres checkpointer, Google ADK with a persistent session service, OpenAI Agents SDK sessions backed by a database, etc.).

### Agent Runtime

The loop itself, plus a context builder (assembles system prompt, memory, retrieved docs, tool schemas in a cache-friendly order), a policy layer (which tools are allowed for this tenant/user/step), and guardrails (input/output classifiers, PII redaction, tool-call validation). Frameworks — OpenAI Agents SDK, Claude Agent SDK, Google ADK, LangGraph, CrewAI, AG2 — live here. The platform should treat the framework as a replaceable component behind a stable internal interface.

### LLM Gateway and Model Router

A single egress point for all model traffic. It normalises provider APIs, enforces quotas, does cross-provider fallback, routes by task difficulty, attaches cost accounting, and is the natural place for semantic/exact caching and prompt-cache-aware request shaping. Covered in depth later.

### Tool Layer

Tools are exposed increasingly via **MCP (Model Context Protocol)** servers — a JSON-RPC protocol where servers advertise tools, resources and prompts, and clients (the agent runtime) invoke them over stdio or Streamable HTTP. Remote MCP servers use OAuth 2.1-based authorization. Inter-agent delegation across organisational boundaries increasingly uses **A2A (Agent2Agent)**, where agents publish an Agent Card describing skills and endpoints and exchange tasks with lifecycle states. The platform's tool layer adds what protocols alone do not: per-tenant credential injection, egress allow-lists, sandboxing for code execution and computer use, timeouts, and audit logs.

### Memory and State

Distinguish carefully:

| Store | Holds | Typical tech | Consistency need |
|---|---|---|---|
| Session/run state | Messages, checkpoints, pending tool calls | Postgres, Temporal history, DynamoDB | Strong, transactional |
| Hot cache | Rate-limit counters, locks, stream buffers | Redis/Valkey | Low latency, best-effort durable |
| Long-term memory | User facts, episodic summaries | Postgres + pgvector, dedicated vector DB | Eventual OK |
| Knowledge/RAG | Document chunks, embeddings | Vector/hybrid search, OpenSearch | Eventual, versioned indexes |
| Artifacts | Files, screenshots, generated reports | S3/GCS | Durable, immutable |
| Trajectory warehouse | Full traces for eval and training | Parquet on object store, ClickHouse, BigQuery | Append-only |

> [!WARNING]
> Storing agent run state only in process memory is the most common production failure for teams moving from prototype. A rolling deploy or OOM kill silently drops every in-flight run; users see a spinner forever. Any run longer than your p99 deploy-drain window must be checkpointed externally.

### Queues

Queues decouple request acceptance from execution, absorb bursts, and provide retry semantics. Use them for long runs, batch jobs (evals, backfills, nightly report agents), and fan-out sub-agent work. Common choices: SQS, Pub/Sub, Kafka (when you also want the event log), Redis Streams, NATS JetStream, or Temporal task queues (which give you queue plus durable state together).

### Observability

Every model call, tool call and agent step should be a span. The OpenTelemetry GenAI semantic conventions define attributes such as model name, token usage, and operation type; most agent frameworks and gateways now emit OTel or integrate with Langfuse, LangSmith, Arize Phoenix, Braintrust, Datadog LLM Observability, and similar. Beyond traces you need a **cost ledger** (per tenant, per feature, per model), and a **trajectory warehouse** that feeds evaluation and post-training.

> [!TIP]
> Staff-level framing: the platform's job is to make the *agent author's* code boring. If every team re-implements retries, fallbacks, budget checks and tracing inside their agent, you have a framework zoo, not a platform. Push cross-cutting concerns down into the gateway, orchestrator and tool layer so that agent code is mostly prompts, tool definitions and policies.

## Request Lifecycle Walkthrough

Consider a user asking a support agent: "Refund my last order and email me the receipt."

1. The gateway authenticates the JWT, resolves tenant `acme`, checks the tenant's request-rate bucket, and upgrades to SSE.
2. The session service creates turn `t_812` with idempotency key derived from client message id; if the key exists it returns the existing run's stream.
3. The orchestrator classifies the turn as potentially side-effecting (refund tool is tagged `side_effect=true, requires_approval_over=100 USD`) and starts a durable workflow.
4. The runtime builds context: static system prompt and tool schemas first (cacheable prefix), then tenant policy, then user memory, then conversation history, then the new message.
5. The router picks a mid-tier model for planning. The gateway checks the tenant token budget, applies the provider prompt-cache key, and calls the provider; tokens stream back through the orchestrator to the SSE channel.
6. The model emits `lookup_order` then `issue_refund(amount=42.00)`. Tool calls go via the tool layer, which injects the tenant's service credential (never visible to the model), enforces a 10-second timeout, and records the call with its idempotency key so a retry cannot double-refund.
7. The model emits `send_email`. The final answer streams to the user. The workflow completes; usage is written to the cost ledger; the trace is sampled into the trajectory warehouse with an outcome label later attached from CSAT data.

## Control Plane vs Data Plane

Mature platforms split:

- **Control plane**: agent definitions, prompt versions, tool registry, model catalogue, routing policies, tenant config, budgets, feature flags, eval results. Low QPS, strongly consistent, audited, changes go through review.
- **Data plane**: the runtime, gateway, tool executors. High QPS, horizontally scaled, reads control-plane config via cached snapshots so that a control-plane outage does not stop serving.

> [!IMPORTANT]
> Data-plane components must keep working with the last known-good configuration when the control plane is unavailable. Design config distribution as versioned immutable snapshots (e.g., `agent_config@v417`) pushed or polled with local caching, never as a synchronous lookup on every request.

# Execution Models: Sync, Async, and Event-Driven

## The Spectrum

| Mode | Latency budget | Transport | State | Example |
|---|---|---|---|---|
| Synchronous inline | under ~30 s | HTTP + streaming | Request-scoped, checkpoint optional | Chat answer with 1-3 tool calls |
| Async job | seconds to hours | Submit + poll/webhook/stream | Durable | Research report, code migration |
| Event-driven reactive | triggered by events | Queue/bus | Durable per entity | Triage every new ticket, react to alert |
| Scheduled / batch | minutes to hours | Cron + queue | Durable | Nightly reconciliation, eval runs |
| Human-in-the-loop | hours to days | Async + notification | Durable with signals | Approvals, escalations |

The deciding question is not "how long does it usually take" but "**what is the p99 duration and what happens if the executing process dies halfway?**" If the answer involves side effects or more than one user-visible minute of lost work, use durable async execution.

## Synchronous Inline

Best for chat-like interactions. The runner holds the request open and streams tokens. Keep the loop bounded: maximum steps (e.g., 8–15), maximum wall-clock (e.g., 60 s), maximum tokens. If a run exceeds limits, hand off to async mode rather than failing — "This is taking longer; I'll notify you when it's done."

```python
# Framework-agnostic pseudocode for a bounded inline loop
async def run_inline(ctx, messages, tools, limits):
    for step in range(limits.max_steps):
        if ctx.elapsed() > limits.max_seconds or ctx.tokens_used > limits.max_tokens:
            return await ctx.escalate_to_async(messages)
        resp = await ctx.llm.stream(messages=messages, tools=tools.schemas())
        async for delta in resp:
            await ctx.emit(delta)          # forward to SSE
        msg = resp.final_message()
        messages.append(msg)
        if not msg.tool_calls:
            return msg
        results = await asyncio.gather(*[
            tools.execute(tc, ctx) for tc in msg.tool_calls
        ], return_exceptions=True)
        messages.extend(to_tool_messages(msg.tool_calls, results))
    return await ctx.escalate_to_async(messages)
```

## Async Job Pattern

```
Client --POST /runs--> API --enqueue--> Queue --> Worker pool
   ^                     |                           |
   |                     +--201 {run_id}             +--> checkpoints to DB
   |                                                 +--> events to stream bus
   +-------- GET /runs/{id}/events (SSE) <-----------+
```

The API returns a run id immediately. The client subscribes to an event stream keyed by run id. Workers publish events to a bus (Redis Streams, Kafka, NATS) and the streaming endpoint tails the bus. This decouples which pod runs the agent from which pod holds the client connection — essential once you have more than one replica.

## Event-Driven Agents

Here agents are consumers of business events: `ticket.created`, `pr.opened`, `alert.fired`. Key design rules:

- **Partition by entity** (ticket id, repo) so events for one entity are processed in order by one consumer at a time; otherwise two agent runs may act on the same ticket concurrently.
- **Make handlers idempotent**; at-least-once delivery is the norm.
- **Emit outcomes as events** (`ticket.triaged`) so other agents or systems chain off them — this is choreography. Contrast with orchestration where a central workflow calls each agent.

| Choreography | Orchestration |
|---|---|
| Loose coupling, easy to add consumers | Central visibility of the whole process |
| Hard to see end-to-end flow | Single place for retries, compensation, timeouts |
| Failure handling distributed | Orchestrator is a dependency and potential bottleneck |
| Good for independent reactive agents | Good for multi-step business processes with SLAs |

> [!TIP]
> Use choreography between bounded contexts (the triage agent and the billing agent are owned by different teams) and orchestration within one (the steps of a single refund process). Mixing both is normal; the anti-pattern is an implicit orchestration hidden inside chains of events nobody can trace.

# Long-Running Agents with Queues, Workers, and Durable Execution

## The Core Problem

An agent that researches for 40 minutes, calling 200 tools, will encounter: provider 529/overloaded errors, rate limits, pod restarts, network partitions, and tool timeouts. Each failure must resume from the last good step, not from scratch, and must never repeat a non-idempotent side effect.

## Three Implementation Approaches

### Approach A: Queue + Workers + Checkpoints (DIY)

Each agent step is a message. A worker pulls a message, loads the checkpoint, performs one step (one model call plus its tool calls), writes the new checkpoint transactionally with the next step message (outbox pattern), and acks.

```python
# Pseudocode: one step per message with transactional outbox
def handle_step(msg):
    run = db.load_run(msg.run_id, for_update=True)
    if run.step_seq >= msg.step_seq:      # duplicate delivery
        return ack(msg)
    result = agent_step(run.state)        # model + tools (tools idempotent by key)
    with db.transaction():
        db.save_state(run.id, result.state, step_seq=msg.step_seq)
        if not result.done:
            db.outbox_insert(topic="agent.steps",
                             payload={"run_id": run.id, "step_seq": msg.step_seq + 1})
        else:
            db.outbox_insert(topic="agent.completed", payload={"run_id": run.id})
    ack(msg)
```

Pros: simple infra, full control. Cons: you re-invent timers, signals, versioning, visibility, and heartbeat handling.

### Approach B: Durable Execution (Temporal and peers)

Temporal models a run as a **workflow** (deterministic code whose execution history is persisted as events) that calls **activities** (non-deterministic work: LLM calls, tool calls) with retry policies. If a worker dies, another replays the workflow history, skipping completed activities by reading their recorded results. This maps almost perfectly onto agent loops: the loop is workflow code, each LLM call and tool call is an activity. Temporal has published integrations for the OpenAI Agents SDK, and similar durable engines (Restate, DBOS, Inngest, AWS Step Functions, Azure Durable Functions) offer comparable semantics.

```python
# Temporal Python SDK style (structure is real; activity bodies elided)
from datetime import timedelta
from temporalio import workflow, activity
from temporalio.common import RetryPolicy

@activity.defn
async def call_llm(req: dict) -> dict:
    ...  # call gateway; raise on retryable errors

@activity.defn
async def run_tool(call: dict) -> dict:
    ...  # execute with idempotency key = call["id"]

@workflow.defn
class AgentWorkflow:
    def __init__(self):
        self.approved: dict[str, bool] = {}

    @workflow.signal
    def approve(self, tool_call_id: str, ok: bool):
        self.approved[tool_call_id] = ok

    @workflow.run
    async def run(self, task: dict) -> dict:
        messages = task["messages"]
        for _ in range(50):
            resp = await workflow.execute_activity(
                call_llm, {"messages": messages},
                start_to_close_timeout=timedelta(minutes=5),
                retry_policy=RetryPolicy(maximum_attempts=5,
                                         backoff_coefficient=2.0))
            messages.append(resp["message"])
            calls = resp["message"].get("tool_calls", [])
            if not calls:
                return resp
            for c in calls:
                if c.get("requires_approval"):
                    await workflow.wait_condition(lambda: c["id"] in self.approved,
                                                  timeout=timedelta(days=2))
                    if not self.approved[c["id"]]:
                        messages.append(tool_msg(c, "Denied by human"))
                        continue
                out = await workflow.execute_activity(
                    run_tool, c, start_to_close_timeout=timedelta(minutes=2))
                messages.append(tool_msg(c, out))
        return {"status": "step_limit"}
```

> [!WARNING]
> Workflow code must be deterministic: no direct LLM calls, `random`, wall-clock time, or network I/O inside the workflow function — use activities and the SDK's deterministic time APIs. A subtle trap: message histories can grow to megabytes and Temporal enforces history and payload size limits. Store large tool outputs in object storage and pass references, and use continue-as-new for very long loops.

### Approach C: Graph Runtime with Checkpointer

LangGraph persists graph state after every super-step through a checkpointer (Postgres, SQLite, Redis); `interrupt` pauses for human input and the run resumes from the thread id. Google ADK sessions and OpenAI Agents SDK sessions provide conversation persistence. These give resumability of *state* but generally not the full retry/timer/worker-lease semantics of a durable execution engine; LangGraph Platform adds a task queue and workers for that.

| Criterion | DIY queue | Temporal-class engine | Graph runtime + checkpointer |
|---|---|---|---|
| Resume after crash | Yes if careful | Yes, built in | Yes from last super-step |
| Human waits of days | Manual timers | Native signals + timers | interrupt + external resume |
| Exactly-once side effects | Your idempotency | Your idempotency (activities are at-least-once) | Your idempotency |
| Workflow versioning | Manual | Patching/worker versioning | Graph schema migrations, manual |
| Ops burden | Low infra, high code | Cluster or cloud service | Low |
| Best for | Simple pipelines | Business-critical, multi-day, multi-agent | Agent-centric apps, fast iteration |

> [!IMPORTANT]
> No engine gives exactly-once execution of external side effects. Activities are retried, so the *tool* must be idempotent: pass an idempotency key (e.g., `run_id:step:tool_call_id`) to downstream APIs that support it (Stripe-style), or record a "started" marker and check-before-act for those that do not.

## Worker Design

- **Separate worker pools by resource profile**: LLM-call-heavy workers are I/O bound (high concurrency per process, async); code-execution or browser/computer-use workers are CPU/memory bound and need sandboxed isolation (gVisor, Firecracker microVMs, Kata).
- **Heartbeats and leases**: a worker holding a 10-minute activity must heartbeat so the orchestrator can detect death quickly rather than waiting the full timeout.
- **Graceful drain**: on SIGTERM, stop pulling new tasks, finish or checkpoint current step, then exit; set Kubernetes `terminationGracePeriodSeconds` longer than the p99 step duration.
- **Backpressure**: workers should pull, not be pushed. Concurrency limits per worker should reflect the downstream LLM quota, not CPU.

> [!TIP]
> Size async worker concurrency against your *token-per-minute quota*, not your pod count. Fifty idle-waiting workers that all fire at once will slam into a 429 wall; a gateway-side token bucket plus queue-depth-based autoscaling keeps throughput at the quota ceiling without thrashing.

# Streaming: SSE, WebSockets, and Event Protocols

## Why Stream

Perceived latency is dominated by time-to-first-visible-output. A 12-second answer that starts rendering at 700 ms feels faster than a 6-second answer delivered all at once. For agents, streaming also conveys *progress*: "Searching orders…", "Calling refund API…", which drastically reduces abandonment during multi-step runs.

## Transport Choices

| Transport | Direction | Pros | Cons | Use when |
|---|---|---|---|---|
| SSE | Server to client | Plain HTTP, proxies friendly, auto-reconnect with Last-Event-ID | One-way; HTTP/1.1 connection limits per domain | Chat output, run progress |
| WebSocket | Bidirectional | Low overhead, client can interrupt/steer mid-run | Stateful connections, harder LB, no built-in resume | Voice, collaborative editing, interruptible agents |
| HTTP streaming (chunked/NDJSON) | Server to client | Simplest | No reconnect semantics | Internal service-to-service |
| WebRTC | Bidirectional media | Lowest latency audio | Complex | Realtime voice agents |
| gRPC streaming | Bidirectional | Typed, efficient | Browser support via proxies | Internal services |

Provider APIs themselves stream via SSE (OpenAI Responses API, Anthropic Messages API, Gemini), and realtime voice APIs use WebSocket or WebRTC. MCP's Streamable HTTP transport can upgrade responses to SSE for server-to-client messages. A2A supports SSE streaming of task updates.

## Designing an Agent Event Schema

Do not forward raw provider deltas to the browser. Define your own typed event stream, so you can switch providers and add agent-level events:

```json
{"id":"412","event":"run.started","data":{"run_id":"r_9","agent":"support@v31"}}
{"id":"413","event":"step.started","data":{"step":1,"kind":"model"}}
{"id":"414","event":"message.delta","data":{"text":"Let me look up"}}
{"id":"418","event":"tool.call","data":{"name":"lookup_order","args_preview":{"order":"last"}}}
{"id":"421","event":"tool.result","data":{"name":"lookup_order","status":"ok","ms":312}}
{"id":"430","event":"approval.required","data":{"tool_call_id":"tc_3","summary":"Refund 42.00 USD"}}
{"id":"455","event":"message.completed","data":{"usage":{"in":5120,"out":210}}}
{"id":"456","event":"run.completed","data":{"status":"success"}}
```

Open protocols such as AG-UI standardise this agent-to-frontend event layer; adopting one (or mirroring its shape) eases frontend reuse.

## Resumable Streams

```
Worker --XADD run:r_9--> Redis Stream <--XREAD from last id-- SSE endpoint (any pod)
                                                     ^
                     Browser reconnects with Last-Event-ID: 421
```

Workers append events to a per-run stream with monotonically increasing ids. The SSE endpoint, on any replica, reads from `Last-Event-ID` onward. This survives client reconnects (mobile network switches) and load-balancer re-routing. Set a TTL on the stream after completion.

```python
# FastAPI SSE endpoint tailing Redis Streams (illustrative)
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import redis.asyncio as redis, json

app = FastAPI(); r = redis.Redis()

@app.get("/runs/{run_id}/events")
async def events(run_id: str, request: Request):
    last = request.headers.get("last-event-id", "0-0")
    async def gen():
        nonlocal last
        while True:
            if await request.is_disconnected():
                break
            resp = await r.xread({f"run:{run_id}": last}, block=15000, count=100)
            if not resp:
                yield ": keepalive\n\n"           # defeat idle timeouts
                continue
            for _, entries in resp:
                for eid, fields in entries:
                    last = eid.decode()
                    evt = fields[b"event"].decode()
                    yield f"id: {last}\nevent: {evt}\ndata: {fields[b'data'].decode()}\n\n"
                    if evt == "run.completed":
                        return
    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})
```

> [!WARNING]
> Proxy buffering silently destroys streaming. Nginx buffers by default (disable via `X-Accel-Buffering: no` or `proxy_buffering off`), some CDNs buffer until the response completes, and compression middleware can hold bytes. Symptom: the stream "works" locally but arrives as one blob in production. Always test streaming through the full production edge path.

> [!WARNING]
> Streaming and output guardrails conflict. If you stream tokens as they arrive, a moderation classifier that flags the full response runs too late — the user already saw it. Options: stream with a lagging buffer (moderate every N tokens/sentence before release), stream only for low-risk surfaces, or retract-and-replace in the UI. Pick explicitly per surface.

## Interruption and Steering

Users want to stop or redirect an agent mid-run. With WebSockets, the client sends `{"type":"cancel"}` or `{"type":"steer","text":"use EU region"}`; with SSE, use a separate POST endpoint that sends a signal to the run (e.g., Temporal signal or a Redis key the loop checks between steps). Cancellation must propagate: abort the in-flight provider stream (saving tokens), cancel pending tool calls if safe, and record the partial state.

> [!TIP]
> Check for cancellation between every step *and* abort the provider HTTP stream on cancel. Reasoning models can burn thousands of hidden reasoning tokens after a user has already navigated away; at scale, unabandoned streams are a measurable percentage of spend.


# Model Routing and Cascading

## The Economic Premise

Model prices span roughly two orders of magnitude between small and frontier models, and latency spans one order. Yet in most agent workloads a large majority of calls — classification, extraction, routing decisions, simple tool-argument filling, summarisation of tool output — are well within the ability of small models. Routing sends each request to the cheapest model that meets its quality bar; cascading tries cheap first and escalates on low confidence.

## Routing Strategies

| Strategy | How it decides | Pros | Cons |
|---|---|---|---|
| Static by step type | Config: planner uses model A, extractor uses model B | Predictable, easy to eval | Leaves savings on table |
| Rule-based | Features: input length, tenant tier, tool count, language | Cheap, explainable | Brittle, manual |
| Learned router | Classifier predicts whether small model will succeed | Adapts to distribution | Needs labelled data, drift |
| Cascade | Try small, verify, escalate if fail | Pays big-model cost only when needed | Latency of failed attempt; needs reliable verifier |
| Ensemble / best-of-n | Multiple models, pick via judge or vote | Highest quality | Most expensive |
| Reasoning-effort routing | Same model, vary reasoning effort/thinking budget | One model to eval | Effort knobs differ by provider |

Most current frontier APIs expose a reasoning effort or thinking-budget parameter. Routing therefore has two axes: *which model* and *how much thinking*. A common production pattern is a fast non-reasoning model for conversational turns and a reasoning model (or high effort) only for planning, code generation, or when the cheap path fails verification.

## Cascade Mechanics

```
request --> small model --> verifier --> pass? --yes--> return
                                |
                                no
                                v
                          large model --> verifier --> return (or human)
```

The economics depend on the verifier. Good verifiers in agent systems are often *programmatic*: JSON schema validation, tool-argument validation against the API, unit tests passing, SQL that parses and returns rows, citations that exist in retrieved documents. LLM-as-judge verifiers work but add cost and their own error rate.

### Worked Cascade Math

Let the small model cost `c_s` = 0.3 units per request, the large model `c_l` = 5 units, the verifier `c_v` = 0.05 units, and the small model passes verification with probability `p` = 0.75.

Expected cost per request with cascade:

```
E[cost] = c_s + c_v + (1 - p) * (c_l + c_v)
        = 0.3 + 0.05 + 0.25 * 5.05
        = 0.35 + 1.2625 = 1.61 units
```

Versus always-large: 5 units. Savings: 68%. The cascade breaks even when `c_s + c_v + (1-p)(c_l + c_v) = c_l`, i.e. when `p = (c_s + c_v) / (c_l + c_v)` ≈ 0.069. So even a small model that passes only 10% of the time saves money in pure cost terms — but latency is the real constraint: failed attempts add the small model's latency to escalated requests. If small takes 1.2 s and large 6 s, p95 latency of escalated requests goes to 7.2 s+.

Also account for **verifier false positives**: if the verifier passes 3% of small-model answers that are actually wrong, quality degrades silently. Measure the router on an eval set with both cost and quality, not cost alone.

```python
# Cascade with programmatic verification (framework-agnostic)
async def cascade(req, tiers, verify):
    last_err = None
    for tier in tiers:                     # e.g. ["small", "medium", "frontier"]
        resp = await gateway.complete(model=tier, **req)
        ok, reason = verify(resp)
        metrics.incr("cascade.attempt", tags={"tier": tier, "ok": ok})
        if ok:
            return resp
        last_err = reason
        req = add_feedback(req, resp, reason)  # optional: tell next tier what failed
    raise CascadeExhausted(last_err)
```

> [!WARNING]
> Router drift: a learned router trained on last quarter's traffic misroutes when product changes introduce new task types. Symptoms are a slow quality decline with *falling* costs — which looks like a win on the FinOps dashboard. Track per-route quality metrics and alert on divergence, not just on spend.

> [!TIP]
> Before building a learned router, measure the ceiling: run your eval set through every candidate model and compute the "oracle routing" cost (cheapest model that got each item right). If oracle savings are under 30%, a static per-step assignment probably captures most of the value with zero operational risk.

## Routing in Multi-Agent Systems

In orchestrator-worker architectures (an orchestrator plans and spawns sub-agents), the orchestrator is usually a frontier reasoning model and sub-agents can be smaller. Anthropic's published experience with multi-agent research systems noted token usage is the dominant driver of both performance and cost, with multi-agent runs consuming many times the tokens of single-agent chats. Routing sub-agents to cheaper models is often the single largest lever.

# LLM Gateways

## Responsibilities

An LLM gateway is a reverse proxy specialised for model APIs. Open-source and commercial options include LiteLLM, Portkey, Kong AI Gateway, Envoy AI Gateway, Cloudflare AI Gateway, Azure API Management AI policies, and in-house builds. Core responsibilities:

1. **Unified API**: one schema (often OpenAI-compatible) mapped to many providers.
2. **Authentication and key management**: virtual keys per team/tenant; provider keys never leave the gateway.
3. **Quotas and rate limits**: requests/min, tokens/min, spend/day by tenant, team, and feature.
4. **Fallbacks and retries**: cross-region, cross-provider, cross-model.
5. **Load balancing**: across deployments (e.g., several Azure OpenAI regions, Bedrock regions, provisioned vs on-demand).
6. **Caching**: exact-match response cache, semantic cache, and prompt-cache-aware routing.
7. **Cost accounting**: tokens times price per model, including cached-token discounts and reasoning tokens.
8. **Policy and safety**: PII redaction, prompt-injection classifiers, data residency routing.
9. **Observability**: OTel spans, request logs (with configurable redaction).

## Rate Limiting with Token Buckets

Providers limit both requests per minute (RPM) and tokens per minute (TPM), sometimes separately for input and output. The gateway must enforce your *internal* allocation of those limits so one tenant cannot starve others.

A token-bucket limiter per (tenant, model) key, with capacity `B` and refill rate `r` tokens/s, admits a request costing `k` tokens if bucket ≥ `k`. The difficulty: output tokens are unknown up front. Common approach — reserve `input_tokens + max_tokens` estimate at admission, then refund the unused portion after completion.

```python
# Redis Lua-backed token bucket with reservation and refund (sketch)
LUA = """
local key, cap, rate, now, cost = KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]),
                                  tonumber(ARGV[3]), tonumber(ARGV[4])
local b = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(b[1]) or cap
local ts = tonumber(b[2]) or now
tokens = math.min(cap, tokens + (now - ts) * rate)
if tokens < cost then
  redis.call('HMSET', key, 'tokens', tokens, 'ts', now)
  return {0, math.ceil((cost - tokens) / rate * 1000)}
end
redis.call('HMSET', key, 'tokens', tokens - cost, 'ts', now)
redis.call('EXPIRE', key, 3600)
return {1, 0}
"""

async def admit(tenant, model, est_in, max_out):
    reserve = est_in + max_out
    ok, retry_ms = await r.eval(LUA, 1, f"tpm:{tenant}:{model}",
                                CAP[tenant], RATE[tenant], time.time(), reserve)
    if not ok:
        raise RateLimited(retry_after_ms=retry_ms)
    return reserve

async def settle(tenant, model, reserved, actual_in, actual_out):
    refund = reserved - (actual_in + actual_out)
    if refund > 0:
        await r.hincrbyfloat(f"tpm:{tenant}:{model}", "tokens", refund)
```

> [!WARNING]
> Reserving `max_tokens` for reasoning models is a trap: reasoning tokens count as output and can be tens of thousands. If you reserve the max you under-admit massively; if you reserve too little you overshoot provider TPM and get 429 storms. Use a per-route rolling p95 of actual output tokens as the reservation and refund/charge the difference.

## Fallback Design

```
primary: provider A, model X, region us-east
  on 429/5xx/timeout --> provider A, model X, region us-west
  on failure         --> provider B, model Y (equivalent tier)
  on failure         --> degraded mode: smaller model + banner, or queue for later
```

Rules for sane fallbacks:

- **Classify errors**: 429 (retry after backoff or fail over), 5xx/529 overloaded (fail over quickly), 400 context-length (do not retry the same; trim or route to a longer-context model), content-policy refusal (do not blindly fail over — another provider may accept content that violates your own policy).
- **Retry budgets**: cap total retries as a fraction of traffic (e.g., retries ≤ 10% of requests) to avoid retry storms amplifying an outage.
- **Circuit breakers**: after N failures in a window, stop sending to that deployment for a cool-down period and probe with a trickle.
- **Hedged requests**: for latency-critical calls, send a second request to another deployment if the first has not produced a first token within the p95 TTFT; cancel the loser. Costs extra tokens only on the slow tail.
- **Prompt equivalence**: each fallback model needs its own tested prompt variant. Tool-calling formats, system-prompt adherence and JSON reliability differ.

| Fallback type | Quality risk | Cost impact | Notes |
|---|---|---|---|
| Same model, other region | None | None | Watch data residency |
| Same model, other provider (e.g., via cloud marketplace) | Very low | Pricing may differ | Feature parity gaps (caching, batch) |
| Different model, same tier | Medium | Similar | Requires per-model prompts and evals |
| Smaller model | High | Lower | Communicate degraded mode |
| Queue for later | None | None | Only for async workloads |

> [!TIP]
> Treat cross-provider fallback as a feature that must be *continuously exercised*. Route 1–5% of production traffic to the secondary provider permanently. Fallback paths that are only used during outages are always broken during outages — expired keys, untested prompts, missing quota.

## Quotas, Budgets, and Hierarchies

Quotas should be hierarchical: organisation → tenant → team/feature → user, each with soft (alert) and hard (block or degrade) limits on spend and tokens. Hard limits for end users should degrade gracefully (switch to cheaper model, reduce max steps) rather than error.

```yaml
# Example gateway budget policy (illustrative schema)
budgets:
  - scope: tenant:acme
    period: month
    soft_limit_usd: 8000
    hard_limit_usd: 10000
    on_hard_limit: degrade        # route to tier "small", max_steps=4
  - scope: tenant:acme/feature:research_agent
    period: day
    hard_limit_usd: 400
    on_hard_limit: queue
  - scope: user:*
    period: day
    hard_limit_tokens: 2_000_000
    on_hard_limit: block_with_message
```

## Caching at the Gateway

| Cache type | Hit condition | Savings | Risk |
|---|---|---|---|
| Provider prompt cache | Identical prefix to a recent request | Large input-cost discount, lower TTFT | None for correctness |
| Exact response cache | Identical full request incl. params | Entire call | Stale answers; only for deterministic tasks |
| Semantic cache | Embedding similarity above threshold | Entire call | Wrong answer for subtly different query; tenant leakage |
| Tool result cache | Same tool + args within TTL | Tool latency/cost | Staleness |

> [!WARNING]
> Semantic caches are dangerous in agents. "Cancel my order 1234" and "Cancel my order 1243" are near-identical embeddings. Never semantic-cache anything that is user-specific, has side effects, or depends on fresh state. Scope all caches by tenant to avoid cross-tenant data leakage.

# Latency Engineering

## Decomposing Agent Latency

For a single model call:

```
latency = network RTT + queueing + prefill(input_tokens) + [reasoning tokens decode] + visible output tokens decode
TTFT  ≈ RTT + queue + prefill (+ reasoning time for reasoning models)
TPOT  = time per output token (inverse of per-stream decode speed)
total ≈ TTFT + output_tokens * TPOT
```

For an agent run:

```
run latency = sum over sequential steps of (model latency + tool latency) + orchestration overhead
```

Key insight: **output tokens and sequential steps dominate**. Prefill is highly parallel on GPUs (thousands of tokens per second per request), decode is sequential (tens to low hundreds of tokens per second per stream). A 2,000-token output at 60 tokens/s is 33 seconds no matter how small the prompt.

## The Latency Levers

| Lever | Mechanism | Typical gain | Cost |
|---|---|---|---|
| Fewer sequential steps | Better planning, parallel tool calls, combine steps | Large | Prompt/eval work |
| Shorter outputs | Concise formats, structured outputs, no preamble | Large | Prompt work |
| Prompt caching | Skip prefill for cached prefix | TTFT down significantly on long prompts | Ordering discipline |
| Smaller/faster model | Faster decode | 2–5x | Quality risk |
| Lower reasoning effort | Fewer hidden tokens | Large for reasoning models | Quality risk |
| Parallel tool calls | Run independent tools concurrently | Sum to max | Need independence |
| Speculative execution | Start likely next step early | Hides latency | Wasted work |
| Streaming | Perceived latency | UX | None |
| Regional proximity | Lower RTT | Tens to hundreds of ms | Residency |
| Provisioned throughput / priority tiers | Lower queueing variance | p99 improvement | Committed spend |

## Parallelism

Modern models emit multiple tool calls in one turn (parallel tool calling). Execute them concurrently with per-tool timeouts. At the architecture level, orchestrator-worker patterns fan out sub-agents in parallel — research agents commonly parallelise searches across sub-agents, trading tokens for wall-clock.

```python
async def exec_parallel(calls, timeout_s=15):
    async def one(c):
        try:
            return await asyncio.wait_for(tools.execute(c), timeout_s)
        except asyncio.TimeoutError:
            return ToolError(c.id, "timeout: tool did not respond in 15s")
    return await asyncio.gather(*(one(c) for c in calls))
```

> [!WARNING]
> Parallel tool calls with hidden dependencies cause race conditions: `create_folder` and `upload_file_to_folder` emitted in the same turn will fail nondeterministically. Mark tools with dependency or side-effect metadata and serialise side-effecting calls targeting the same resource, or instruct the model (and validate) that dependent calls must be in separate turns.

## Speculative Execution at the Agent Level

Distinct from speculative *decoding* (an inference-engine technique covered later), agent-level speculation means starting work before you know you need it:

- **Speculative retrieval**: kick off RAG retrieval on the user message in parallel with the router/planner call; most turns need it anyway.
- **Speculative tool prefetch**: when the user opens an order page, prefetch order details so the first tool call is a cache hit.
- **Speculative model calls**: run the cheap model and the expensive model concurrently, return the cheap one if it verifies, cancel the expensive one — trades cost for cascade latency.
- **Predicted outputs**: some APIs accept a predicted output (e.g., when editing a file where most content is unchanged), letting the server verify spans instead of generating them.

## Prompt Caching

Providers cache the KV state of prompt prefixes. Mechanics differ:

| Aspect | OpenAI | Anthropic | Google Gemini |
|---|---|---|---|
| Activation | Automatic for prompts above a minimum length (around 1,024 tokens) | Explicit `cache_control` breakpoints on content blocks (also automatic options in newer setups) | Implicit caching on recent models plus explicit cached content objects |
| Discount on cached input | Substantial (model-dependent, commonly 50–90%) | Cache reads around 10% of base input price | Discounted cached-token rate |
| Write cost | None extra | Cache writes priced above base input (about 1.25x for 5-min TTL, higher for 1-hour TTL) | Storage cost for explicit caches |
| TTL | Minutes, best-effort, extended retention options | 5 minutes default, 1-hour option | Configurable for explicit caches |
| Routing hint | `prompt_cache_key` parameter to improve hit rate | Breakpoint placement | Cache object reference |

Exact percentages change; verify current pricing pages. The structural rule is universal: **caching matches on exact prefix**. Order context from most static to most dynamic:

```
[1] system prompt (static, versioned)         <- cache breakpoint
[2] tool definitions (static per agent version)
[3] few-shot examples / long reference docs   <- cache breakpoint
[4] tenant / user memory (changes rarely)     <- cache breakpoint
[5] conversation history (append-only)        <- cache breakpoint at last turn
[6] new user message / latest tool results
```

```python
# Anthropic Messages API with cache breakpoints (Python SDK shape)
resp = client.messages.create(
    model=MODEL,
    max_tokens=1024,
    system=[
        {"type": "text", "text": SYSTEM_PROMPT_V31},
        {"type": "text", "text": POLICY_HANDBOOK,          # ~20k tokens
         "cache_control": {"type": "ephemeral"}},
    ],
    tools=TOOLS_V31,
    messages=history + [{"role": "user", "content": user_msg}],
)
u = resp.usage
log(cache_read=u.cache_read_input_tokens, cache_write=u.cache_creation_input_tokens,
    uncached=u.input_tokens, out=u.output_tokens)
```

> [!WARNING]
> Cache killers: a timestamp or request id in the system prompt; non-deterministic JSON key ordering when serialising tool schemas; dynamically reordering tools per request; injecting retrieved documents *before* the static instructions; editing earlier conversation turns (e.g., rolling summarisation that rewrites history each turn). Any byte change invalidates everything after it. Monitor `cached_tokens / input_tokens` per route as a first-class SLI.

> [!TIP]
> For agent loops, the conversation grows by appending tool results, so each step re-sends the previous prefix. With good caching, a 20-step agent with a 30k-token context pays full price for roughly one prefix and discounted price for the rest. Without caching, input cost grows quadratically with steps. Caching is not an optimisation for agents; it is what makes long loops economically viable.

## Latency SLOs for Agents

Define SLOs per interaction class, not one global number:

| Class | TTFT/first-event SLO (p95) | Completion SLO (p95) |
|---|---|---|
| Conversational answer | under 1.5 s first event | under 8 s |
| Tool-using turn (1–3 tools) | under 1.5 s first progress event | under 20 s |
| Research/async task | under 2 s acknowledgment | Minutes; progress events every 10 s |
| Voice agent | under 500–800 ms response onset | Turn-based |

Measure first *meaningful* event (a status or first token), not HTTP 200.

# Cost Engineering and Token Budgets

## Anatomy of Agent Cost

```
cost_per_task = sum over model calls of [
     uncached_in * p_in + cached_in * p_cached + cache_write * p_write
   + (reasoning_out + visible_out) * p_out ]
 + tool costs (search API, sandboxes, browsers)
 + embedding / retrieval costs
 + infra (orchestrator, storage, observability)
 + human review costs (often the largest, often ignored)
```

Unit economics should be expressed **per successful task**, not per token or per request: `cost_per_success = total_cost / successful_tasks`. An agent with a 60% success rate at 0.10 USD per attempt costs 0.167 USD per success, plus the cost of the failures handled by humans.

## Worked FinOps Example

Scenario: customer-support agent, 1.2 million conversations/month, average 3 user turns per conversation, average 4 model calls per turn (planner + tool loops), hence 14.4 million model calls/month.

Per-call token profile (averages):

- Static prefix (system + tools + policy): 12,000 tokens
- Dynamic context (memory + history + tool results): 4,000 tokens
- Output: 250 visible tokens, 0 reasoning (non-reasoning model for most calls)

Illustrative prices for a mid-tier model (use your own contracted prices): input 2.50 USD per million tokens, cached input 0.25 USD per million, output 10 USD per million.

**Scenario A — no caching:**

```
input  = 16,000 tok * 14.4M calls = 230.4B tokens * 2.50/M  = 576,000 USD
output = 250 tok * 14.4M = 3.6B tokens * 10/M               =  36,000 USD
total                                                        = 612,000 USD/month
```

**Scenario B — prompt caching with 85% hit rate on the 12k static prefix, plus half of dynamic context cached (history prefix):**

```
cached tokens per call   = 0.85*12,000 + 0.5*4,000 = 10,200 + 2,000 = 12,200
uncached tokens per call = 16,000 - 12,200 = 3,800
cached  = 12,200 * 14.4M = 175.7B * 0.25/M = 43,920 USD
uncached= 3,800  * 14.4M =  54.7B * 2.50/M = 136,800 USD
output  =                                       36,000 USD
total                                         ≈ 216,700 USD/month   (-65%)
```

**Scenario C — B plus routing:** 70% of calls (extraction, classification, simple replies) move to a small model at one-tenth the price.

```
large share (30%): 216,700 * 0.30          = 65,010 USD
small share (70%): 216,700 * 0.70 * 0.10   = 15,169 USD
router overhead (tiny classifier ~ 1% of B) ≈  2,000 USD
total                                       ≈ 82,200 USD/month   (-87% vs A)
```

**Scenario D — C plus step reduction:** better planning and parallel tool calls drop average model calls per turn from 4 to 3 (−25%) → about 61,600 USD/month.

The lesson: **caching, routing and step count are multiplicative**, and step count also reduces latency. Prompt micro-trimming of a few hundred tokens barely registers by comparison.

Now compare to the value side: if each conversation deflected from a human agent saves 4 USD and the agent fully resolves 55% of conversations, value is 1.2M × 0.55 × 4 = 2.64M USD/month. Even Scenario A is profitable; but Scenario A at 3x traffic with reasoning models might not be. Always present both sides.

> [!WARNING]
> Reasoning tokens are invisible output tokens billed at output rates. Switching a route from a non-reasoning model to a reasoning model at "the same price per token" can multiply cost 5–20x because each call emits thousands of hidden reasoning tokens. Track `reasoning_tokens` separately in your cost ledger and set reasoning effort explicitly per route.

## Token Budgets in the Agent Loop

Budgets should exist at several levels:

- **Per call**: `max_output_tokens`, reasoning effort/budget.
- **Per run**: total tokens and dollars; checked before each step.
- **Per context window**: cap on context size, triggering compaction (summarise older turns, drop stale tool outputs, offload to files/memory).
- **Per tenant/period**: enforced by the gateway.

```python
class RunBudget:
    def __init__(self, usd_limit, token_limit):
        self.usd_limit, self.token_limit = usd_limit, token_limit
        self.usd = 0.0; self.tokens = 0

    def charge(self, usage, price):
        self.tokens += usage.input + usage.output
        self.usd += (usage.uncached_in * price.inp + usage.cached_in * price.cached
                     + usage.output * price.out) / 1e6

    def check(self, projected_usd=0.0):
        if self.usd + projected_usd > self.usd_limit:
            raise BudgetExceeded("usd", self.usd)
        if self.tokens > self.token_limit:
            raise BudgetExceeded("tokens", self.tokens)
```

On `BudgetExceeded`, do not just crash: ask the model to produce a best-effort final answer with what it has (one bounded call), or hand off to a human.

## Context Compaction Economics

Long agent runs accumulate tool outputs. Strategies:

| Strategy | Effect on cost | Effect on cache | Risk |
|---|---|---|---|
| Truncate old tool outputs | Lower input | Breaks cache at truncation point | Lose detail |
| Periodic summarisation (compaction) | Much lower input | Breaks cache once per compaction | Summary loses facts |
| Offload to files/memory, keep pointers | Lower input | Stable if done append-only | Model must re-fetch |
| Sub-agents with isolated contexts | Lower per-context size | Each sub-agent has own cache | More total tokens possible |

> [!TIP]
> Compact in discrete epochs (e.g., when context passes 70% of the window), not every turn. Every compaction invalidates the cache for the suffix; compacting once per 20 turns costs one cache write, compacting every turn defeats caching entirely. The Claude Agent SDK and several frameworks provide built-in compaction for exactly this reason.

## Batch and Flex Tiers

Major providers offer batch APIs (asynchronous, typically within 24 hours) at around a 50% discount, and some offer flex/priority tiers trading latency for price. Route offline workloads — evals, backfills, nightly summarisation, synthetic data generation, trajectory labelling — to batch. A platform should make "batch-eligible" a property of the job, with the gateway choosing the API.

## FinOps Operating Model

- **Showback/chargeback** by tenant, team, feature via gateway tags.
- **Unit metrics dashboards**: cost per successful task, cost per active user, cached-token ratio, reasoning-token share, retries share.
- **Anomaly detection**: an agent stuck in a loop can spend thousands of dollars in an hour; alert on per-run spend over threshold and per-tenant spend velocity.
- **Commitment management**: provisioned throughput or committed-use discounts once baseline traffic is predictable; keep bursts on on-demand.

> [!WARNING]
> Runaway loops are the costliest agent failure mode: a tool returns an error the model cannot fix, the model retries forever. Hard step limits, repeated-identical-call detection (same tool + same args three times → abort), and per-run spend caps are mandatory, not optional.

