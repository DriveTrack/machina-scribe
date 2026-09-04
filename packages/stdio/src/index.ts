#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { Store, TOOLS } from '@scribe/mcp-core';

import { loadEnv } from './env.js';

serveStdio(() => {
  const env = loadEnv();
  const store = new Store({
    supabaseUrl: env.supabaseUrl,
    supabaseKey: env.supabaseKey,
    userId: env.userId
  });
  const server = new McpServer({ name: 'machina-scribe', version: '0.1.0' });

  for (const tool of TOOLS) {
    server.registerTool(
      tool.name,
      {
        description: tool.description,
        // This SDK wants a schema object, so the shared raw shape gets wrapped.
        inputSchema: z.object(tool.inputShape as never)
      },
      async (args: Record<string, unknown>) => ({
        content: [{ type: 'text' as const, text: await tool.run(store, args) }]
      })
    );
  }

  return server;
});
