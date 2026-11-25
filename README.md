# Agentic AI Engineering Mastery Suite (Senior / Staff / Lead)

An empirically grounded, production-grade study curriculum and hard-level question bank for **Senior, Staff, and Lead Agentic AI Engineers**, synthesized from **75 real-world job profiles** across frontier AI labs, hyperscalers, enterprise platforms, and AI-native startups.

All materials are available in two fully formatted formats:
- **Interactive Web Edition (`html/`):** Responsive dark/light theme, KaTeX LaTeX mathematical formula rendering, Prism.js syntax-highlighted code blocks with copy buttons, unified sidebar navigation, and in-page Table of Contents.
- **Microsoft Word Edition (`out/`):** Professional OpenXML `.docx` files with native Table of Contents fields, styled headings, color-coded callouts, and page numbers.

🌐 **Portal Dashboard:** Launch [index.html](file:///h:/Agentic-AI-Study-Material/index.html) to browse the complete suite in your browser.

---

## Deliverables & Learning Modules

| Volume | Title | Web Edition (HTML + Math + Code) | Word Edition (.docx) | Highlights & Topics |
|---|---|---|---|---|
| **00** | **Job Market Analysis & Master Syllabus** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/00_Agentic_AI_Job_Market_Analysis_and_Master_Syllabus.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/00_Agentic_AI_Job_Market_Analysis_and_Master_Syllabus.docx) | 75-Job Catalog, 50+ Topic Frequency Matrix, Hiring Filters by Tier, Staff Interview Structure, 8–10 Week Study Plan. |
| **01** | **Agent Foundations & Cognitive Architectures** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/01_Agent_Foundations_and_Cognitive_Architectures.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/01_Agent_Foundations_and_Cognitive_Architectures.docx) | Autonomy spectrum, ReAct, Plan-and-Execute, ReWOO, Reflexion, LATS, State Machines, Reasoning models (o3, Claude Thinking), Test-time compute. |
| **02** | **Tool Use, Function Calling & Protocols** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/02_Tool_Use_Function_Calling_and_Protocols.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/02_Tool_Use_Function_Calling_and_Protocols.docx) | Constrained decoding, ACI design, **Model Context Protocol (MCP)** host/client/server, stdio/HTTP, **Agent2Agent (A2A)**, CodeAct, Firecracker sandboxing. |
| **03** | **Memory, Context Engineering & Agentic RAG** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/03_Memory_Context_Engineering_and_Agentic_RAG.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/03_Memory_Context_Engineering_and_Agentic_RAG.docx) | Context rot mitigations, Letta/MemGPT memory, KV-cache prompt caching layout for 95%+ hits, Hybrid RAG (Dense+BM25 with RRF), Cross-encoders, Self-RAG, GraphRAG, ACLs. |
| **04** | **Multi-Agent Systems & Orchestration** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/04_Multi_Agent_Systems_and_Orchestration.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/04_Multi_Agent_Systems_and_Orchestration.docx) | Multi-agent justification threshold, Supervisor vs Swarm handoffs, LangGraph checkpointers, Temporal durable execution, HITL interrupts, Sagas, Concurrency reducers. |
| **05** | **Evaluation, Observability & Reliability** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/05_Evaluation_Observability_and_Reliability.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/05_Evaluation_Observability_and_Reliability.docx) | Trajectory vs outcome evals, Golden sets, LLM-as-a-judge calibration (Cohen's kappa), pass@k vs pass^k, SWE-bench/Tau-bench, OpenTelemetry GenAI standards, SLOs. |
| **06** | **Security, Guardrails & Enterprise Governance** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/06_Security_Guardrails_and_Enterprise_Governance.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/06_Security_Guardrails_and_Enterprise_Governance.docx) | OWASP Agentic Top 10, Lethal Trifecta, Indirect prompt injection, Dual-LLM pattern, CaMeL taint tracking, MCP security, OAuth 2.1 RFC 8693, EU AI Act compliance. |
| **07** | **Production Architecture, Deployment & LLMOps** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/07_Production_Architecture_Deployment_and_LLMOps.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/07_Production_Architecture_Deployment_and_LLMOps.docx) | Reference enterprise platform, Kafka event-driven agents, SSE token streaming, Model cascades, Worked FinOps math, Self-hosted vLLM/SGLang, Post-training (SFT, RLVR, GRPO). |
| **08** | **System Design Blueprints & Case Studies** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/08_System_Design_Blueprints_and_Case_Studies.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/08_System_Design_Blueprints_and_Case_Studies.docx) | **7 Complete Staff System Designs** (Coding Agent, 50M-Doc ACL RAG, Financial Support, Deep Research, Computer Use, 1000-Team Platform, Compliance Agent) + 8-Step Interview Framework. |
| **09** | **Hard-Level Question Bank & Solutions** | [Read Online](file:///h:/Agentic-AI-Study-Material/html/09_Agentic_AI_Hard_Question_Bank_and_Solutions.html) | [Download .docx](file:///h:/Agentic-AI-Study-Material/out/09_Agentic_AI_Hard_Question_Bank_and_Solutions.docx) | **120 Hard/Very Hard Multi-Part Questions with Comprehensive Staff-Level Model Answers**, trade-off tables, common pitfall warnings, and interviewer follow-up probes across all 8 domains. |

---

## Technical Features of the Web Edition

1. **LaTeX Math Rendering:** Math equations (both display `$$...$$` and inline `$...$`) are parsed and rendered with **KaTeX** for vector-quality mathematical typesetting. Price signs (e.g. `\$0.30/M`) are sanitized to prevent collision with math delimiters.
2. **Prism Syntax Highlighting:** Monospace code blocks are styled with language detection (`python`, `json`, `bash`, `sql`), line formatting, and a 1-click **Copy to Clipboard** button.
3. **Responsive Two-Rail Layout:** Features a fixed left navigation sidebar for rapid cross-volume jumping and a right-rail sticky **On This Page** Table of Contents.
4. **Instant Theme Switching:** Toggle between Dark Mode and Light Mode with preferences persisted across sessions.
5. **Real-Time Client-Side Filtering:** Search input in the sidebar and dashboard enables instant keyword filtering across volumes.

---

## Compilation Tooling

- Markdown to Word: `tools/md2docx.ps1`
- Markdown to HTML: `tools/md2html.ps1`
