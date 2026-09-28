# Agent Note: NInfer native support on 0.2.0-rc.1

Status: implemented

English | [中文](2026-09-28-ninfer-native-020.zh.md)

## Problem

The previous native fork used pre-V4 messages, settings and preset contracts. A direct package upgrade lost exact request admission and safe handling of incomplete native output.

## Decision

Keep the upstream 0.2.0-rc.1 message projection and add optional prepared inspection. Native recovery runs before tool execution and ordinary providers retain upstream behavior. Persisted SDK sessions load before resume. The legacy reader promotes only exact version-2 one-shot subagent descriptors, whose identity is unchanged in version 3.

## Alternatives considered

Reapplying the old loop wholesale would discard V4 tool-update projection. Rewriting every old descriptor would accept unsupported continuable sessions. Both are rejected.

## Consequences

NInfer and recovery plugins require this fork. Stock providers do not need inspection. The 33 histories with unsupported shapes remain outside the active home. Rollback restores the previous runtime together with its matching home.

## Verification

Core build; LLM, agent-loop, compaction, SDK and migration suites; six recovery SDK cases; real NInfer text and filesystem calls; OpenDesign stdio; Web plugin, search, fetch and download checks. The retained history converts without failures.
