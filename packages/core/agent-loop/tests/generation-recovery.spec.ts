import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import LlmRuntime, { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineContentToolFixture } from '@deepseek-ai/dsh-tools'
import { MockAdapter, maxTokensResponse, textResponse, toolCallResponse } from './mock-adapter.ts'

async function harness(adapter: MockAdapter) {
  const ctx = new Context()
  for (const plugin of [LlmRuntime, SessionStore, SessionProjectionRegistry, SystemPrompt, ToolRuntime, AgentRegistry]) {
    await ctx.plugin(plugin)
  }
  await ctx.plugin(AgentLoop, { agents: [] })
  ctx.llm.registerAdapter(['mock'], adapter)
  return ctx
}

describe('generation recovery before tool execution', () => {
  it('restores compacted runtime instructions before reinspecting and streaming the same step', async () => {
    const adapter = new MockAdapter([textResponse('done')])
    const ctx = await harness(adapter)
    try {
      const instruction = 'Delivery key: current-key. Preserve this instruction verbatim.'
      ctx.systemPrompt.context({ name: 'delivery', order: 0, text: instruction })
      let admissions = 0
      ctx.on('agent/request-prepared', async ({ agent, request }, next) => {
        admissions += 1
        const texts = request.messages.flatMap(message => message.content)
          .flatMap(block => block.type === 'text' ? [block.text] : [])
        expect(texts.some(text => text.includes(instruction))).toBe(true)
        if (admissions !== 1) return next()
        const context = agent.session.snapshotEvents().find(event => event.type === 'user/message'
          && event.data.source.kind === 'plugin'
          && event.data.source.plugin === '@deepseek-ai/dsh-system-prompt')
        if (context?.type !== 'user/message') throw new Error('Missing context snapshot')
        agent.session.append('user/message', createUserMessage({
          content: [{ type: 'text', text: 'Compacted summary without the exact delivery key.' }],
          source: { kind: 'plugin', plugin: 'test-compaction' },
        }), {
          surfaceOp: { op: 'replace', startSeq: context.seq, endSeq: context.seq },
          sourceEventSeqs: [context.seq],
        })
        await next()
        return { kind: 'retry' }
      })
      const agent = await ctx.agentLoop.create(SessionId('compacted-admission'), { provider: 'mock', model: 'mock' })
      agent.followup(createUserMessage({ content: [{ type: 'text', text: 'build' }], source: { kind: 'user' } }))
      await agent.whenIdle()
      expect(admissions).toBe(2)
      expect(adapter.requests).toHaveLength(1)
      expect(adapter.requests[0]?.messages.flatMap(message => message.content)
        .some(block => block.type === 'text' && block.text.includes(instruction))).toBe(true)
      const snapshots = agent.session.snapshotEvents().filter(event => event.type === 'user/message'
        && event.data.source.kind === 'plugin'
        && event.data.source.plugin === '@deepseek-ai/dsh-system-prompt')
      expect(snapshots).toHaveLength(2)
      expect(agent.session.snapshotEvents().filter(event => event.type === 'turn/end').at(-1)?.data)
        .toMatchObject({ reason: { kind: 'completed' } })
    } finally { await ctx.fiber.dispose() }
  })

  it('retains the failed batch only as an attempt and does not repeat a preceding tool', async () => {
    const interrupted = toolCallResponse('never-run', 'echo', { text: 'partial' })
    interrupted[interrupted.length - 1] = { type: 'finish', reason: { kind: 'max-tokens' } }
    const adapter = new MockAdapter([toolCallResponse('first','echo',{ text:'first' }), interrupted, toolCallResponse('second','echo',{ text:'second' }),textResponse('done')])
    const ctx = await harness(adapter)
    try {
      const executed: string[] = []
      ctx.tools.register(defineContentToolFixture({ name:'echo',description:'echo',parameters:{ text:{ type:'string' } },async execute(args) { executed.push(String(args.text)); return [{ type:'text',text:'recorded' }] } }))
      ctx.on('agent/response-incomplete', async ({ agent,attemptSeq }) => {
        expect(agent.session.snapshotEvents().find(e=>e.seq===attemptSeq)?.type).toBe('assistant/attempt')
        return { kind:'retry',context:createUserMessage({ content:[{ type:'text',text:'Continue with a smaller operation.' }],source:{ kind:'plugin',plugin:'test-recovery' } }) }
      })
      const agent = await ctx.agentLoop.create(SessionId('recover-batch'),{ provider:'mock',model:'mock' })
      agent.followup(createUserMessage({ content:[{ type:'text',text:'write' }],source:{ kind:'user' } }))
      await agent.whenIdle()
      expect(executed).toEqual(['first','second'])
      const events = agent.session.snapshotEvents()
      expect(events.filter(e=>e.type==='assistant/attempt')).toHaveLength(1)
      expect(events.filter(e=>e.type==='agent/generation-recovery')).toHaveLength(1)
      expect(events.filter(e=>e.type==='turn/end').at(-1)?.data).toMatchObject({ reason:{ kind:'completed' } })
      expect(adapter.requests[2]?.messages.flatMap(m=>m.content).some(b=>b.type==='tool-call'&&b.id==='never-run')).toBe(false)
    } finally { await ctx.fiber.dispose() }
  })
  it('leaves an unrecovered limit explicit without retaining broken conversation text', async () => {
    const ctx = await harness(new MockAdapter([maxTokensResponse('<tool_call>broken')]))
    try {
      const agent = await ctx.agentLoop.create(SessionId('unrecovered'),{ provider:'mock',model:'mock' })
      agent.followup(createUserMessage({ content:[{ type:'text',text:'write' }],source:{ kind:'user' } }))
      await agent.whenIdle()
      const events = agent.session.snapshotEvents()
      expect(events.filter(e=>e.type==='assistant/message')).toHaveLength(0)
      expect(events.filter(e=>e.type==='assistant/attempt')).toHaveLength(1)
      expect(events.filter(e=>e.type==='turn/end').at(-1)?.data).toMatchObject({ reason:{ kind:'max-tokens' } })
    } finally { await ctx.fiber.dispose() }
  })
  it('cancellation during recovery prevents another generation', async () => {
    const adapter = new MockAdapter([maxTokensResponse('partial'),textResponse('must not run')])
    const ctx = await harness(adapter)
    try {
      ctx.on('agent/response-incomplete', async ({ agent }) => { agent.cancel({ kind:'user' }); return { kind:'retry' } })
      const agent = await ctx.agentLoop.create(SessionId('cancel-recovery'),{ provider:'mock',model:'mock' })
      agent.followup(createUserMessage({ content:[{ type:'text',text:'write' }],source:{ kind:'user' } }))
      await agent.whenIdle()
      expect(adapter.requests).toHaveLength(1)
      expect(agent.session.snapshotEvents().filter(e=>e.type==='turn/end').at(-1)?.data).toMatchObject({ reason:{ kind:'aborted' } })
    } finally { await ctx.fiber.dispose() }
  })
})
