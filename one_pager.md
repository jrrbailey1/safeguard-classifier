# AI Prompt Safety Classification — Executive Overview

---

## What We Are Building

As HSBC deploys AI agents and large language models (LLMs) into internal workflows, those systems accept natural-language input from users. This creates an attack surface: a malicious or misconfigured prompt can manipulate an AI into ignoring its instructions, exposing confidential data, or taking actions it was never intended to take.

We have built an **automated prompt screening pipeline** that intercepts every message sent to an AI system and classifies it for safety violations before it can cause harm.

The pipeline uses **GPT-OSS-Safeguard-20b**, a specialist open-source AI safety model deployed on Google Cloud (Vertex AI). It evaluates each prompt against seven threat categories and returns a structured verdict — violation type, confidence level, and the exact phrase that triggered the flag — in under two seconds. Results are written to BigQuery for audit, reporting, and downstream alerting.

---

## What It Detects

| Category | Example |
|---|---|
| **Prompt injection** | Hidden instructions inside documents or emails that attempt to override the AI's behaviour |
| **Jailbreak** | Attempts to bypass safety guidelines via roleplay, fictional framing, or fake personas ("DAN mode") |
| **Red team reconnaissance** | Adversarial probing — mapping the AI's limits before launching a targeted attack |
| **Harassment** | Threats or encouragement of self-harm directed at individuals |
| **Hate speech** | Slurs or hostility toward protected groups |
| **Violence** | Content promoting or inciting physical harm |
| **Illegal content** | Requests for instructions relating to crimes or dangerous acts |

---

## Results So Far

Tested against 200 prompts — 150 adversarial attacks across three categories, 50 completely benign:

| Category | Recall |
|---|---|
| Prompt injection | 98% |
| Jailbreak | 100% |
| Red team | 100% |
| **False positive rate** | **0%** |

149 out of 150 attacks detected. Zero legitimate prompts incorrectly flagged. The pipeline runs continuously, classifying new prompts every five minutes with no manual intervention.

---

## Why This Matters

AI systems at the scale HSBC operates present a meaningful adversarial surface. The threats are not theoretical:

- **Prompt injection** is an established attack vector against LLM-powered systems. A malicious instruction embedded in a customer email, document, or data feed can silently redirect an AI agent's behaviour without the user or operator knowing.
- **Jailbreaks** allow users to strip away safety controls, potentially extracting sensitive training data, generating policy-violating content, or manipulating the AI into performing restricted actions.
- **Red team probes** are a precursor to more targeted attacks — an adversary mapping the system's limits today is preparing a more sophisticated exploit tomorrow.

Without a detection layer, these attacks are invisible. They leave no trace in application logs, trigger no alerts, and are indistinguishable from legitimate traffic.

---

## Risk of Not Implementing

| Risk | Consequence |
|---|---|
| **Data leakage** | Prompt injection via document or email content could cause an AI agent to exfiltrate confidential data or reveal its system instructions |
| **Regulatory exposure** | Undetected generation of harmful, discriminatory, or illegal content creates liability under FCA conduct rules and EU AI Act obligations |
| **Reputational damage** | A publicly disclosed AI safety failure at a systemically important bank carries significant reputational cost |
| **Operational manipulation** | An AI agent acting on injected instructions could take unintended actions — approving transactions, modifying records, or escalating privileges |
| **No audit trail** | Without classification logs, there is no forensic evidence to investigate an incident or demonstrate due diligence to regulators |

The cost of a safety failure — remediation, regulatory scrutiny, reputational damage — is orders of magnitude greater than the cost of this control.

---

## Next Steps

The current system operates in **monitoring mode** — prompts are classified and logged after the fact. The immediate next step is to wire the classifier **inline**, so adversarial prompts are **blocked before they reach the AI model**. This transforms the system from an audit trail into an active control.

Longer term: real-time alerting for high-confidence violations, a Looker Studio dashboard for security operations, and MITRE ATLAS taxonomy tagging for SOC integration.

---

*Pipeline: Google Cloud (Vertex AI · Cloud Run · BigQuery · Cloud Scheduler) | Model: GPT-OSS-Safeguard-20b | Classification latency: <2 seconds*
