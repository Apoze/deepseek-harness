# Agent Note: Native generation admission and bounded recovery

Status: implemented

English | [中文](2026-09-09-native-generation-admission.zh.md)

## Problem

A response limit can split a native tool call. Finalizing that generation pollutes replay with incomplete syntax and prevents the harness from finishing recoverable work. Pressure measured before new input cannot admit the final request accurately.

## Decision

The LLM seam exposes optional inspection of the same projected request that it dispatches. The agent loop records inspection and awaits final admission. Limited or structurally invalid generations settle as durable attempts before a recovery waterfall; accepted responses alone reach tool execution. Policies own retry budgets and recorded technical context. The native NInfer adapter owns wire preparation and server counting; no parser of displayed prose executes commands.

The existing compactor owns balanced reduction and rejects unusable summaries before replacement. Auxiliary calls have separate reasoning/tool/output settings and durable request records. Metering distinguishes current input from cumulative attempt usage. A named SDK session resumes through the existing registry after a process restart, with workspace identity checked.

Retries restore runtime context removed by compaction from the existing prompt assembly before exact counting; they do not readmit user input. Punctuation-only summaries fail before replacement. Compaction honors recent-history retention even when that means no range can be reduced.

## Alternatives considered

A retry after turn completion is too late to preserve one coherent result. A network retry repeats the same oversized generation. Prefix concatenation can invent executable arguments. A new transactional writer would duplicate tools and would not fix request capacity.

## Consequences

Rejected attempts never execute a partially accepted tool batch. Optional provider capabilities leave other adapters on their existing path. Exact counting does not predict output length or guarantee semantic correctness. Bounded recovery can still end incomplete. Required events need this reader version; deployments retain original session generations for rollback. Verification covers actual tool effects, protocol limits, cancellation, loaded-context summarization and process restart, plus SDK and session replay snapshots.
