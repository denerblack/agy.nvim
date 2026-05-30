#!/usr/bin/env node
// agy.nvim — MCP bridge between the agy CLI and a running Neovim.
//
// Exposes the editor context (active file, visual selection, open files) as MCP
// tools so agy can pull in what you are working on — the robust equivalent of
// the Claude Code editor integration, over the channel agy actually supports.
//
// Transport: MCP stdio (newline-delimited JSON-RPC 2.0).
// Neovim access: shells out to `nvim --server <socket> --remote-expr "luaeval(...)"`,
// so it needs no npm dependencies. The socket comes from $NVIM (set automatically
// for processes running inside Neovim's :terminal), or $NVIM_SOCKET, or --server.
//
// The Lua side lives in lua/agy/mcp.lua and must be on Neovim's runtimepath
// (it is, when agy.nvim is installed).

import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const SERVER_INFO = { name: "agy-nvim", version: "0.1.0" };
const DEFAULT_PROTOCOL = "2025-06-18";

// Optional debug log: set AGY_MCP_DEBUG=/path/to/log to trace lifecycle/requests.
function debug(line) {
  const f = process.env.AGY_MCP_DEBUG;
  if (!f) return;
  try {
    appendFileSync(f, `[${process.pid}] ${line}\n`);
  } catch {}
}
debug(`started; NVIM=${process.env.NVIM || ""}`);

function socketAddr() {
  const argIdx = process.argv.indexOf("--server");
  if (argIdx !== -1 && process.argv[argIdx + 1]) return process.argv[argIdx + 1];
  return process.env.NVIM || process.env.NVIM_SOCKET || process.env.NVIM_LISTEN_ADDRESS || "";
}

// Call a lua function in agy.mcp on the connected Neovim and return parsed JSON.
function nvimCall(fn) {
  const sock = socketAddr();
  if (!sock) {
    return { ok: false, reason: "no Neovim socket ($NVIM unset); is agy running inside Neovim?" };
  }
  const expr = `luaeval("require([[agy.mcp]]).${fn}()")`;
  const res = spawnSync("nvim", ["--server", sock, "--remote-expr", expr], {
    encoding: "utf8",
    timeout: 5000,
  });
  if (res.error) return { ok: false, reason: `nvim spawn failed: ${res.error.message}` };
  if (res.status !== 0) {
    return { ok: false, reason: `nvim error: ${(res.stderr || "").trim() || "exit " + res.status}` };
  }
  try {
    return JSON.parse((res.stdout || "").trim());
  } catch (e) {
    return { ok: false, reason: `bad JSON from nvim: ${e.message}` };
  }
}

const TOOLS = [
  {
    name: "neovim_active_file",
    description:
      "Get the file the user is currently editing in Neovim, with its live content " +
      "(including unsaved changes). Use this to know what the user is looking at.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: () => nvimCall("active_file"),
  },
  {
    name: "neovim_selection",
    description:
      "Get the user's most recent visual selection in Neovim: the file, the line " +
      "range, and the selected text. Use this when the user refers to 'this' / the " +
      "selected code.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: () => nvimCall("selection"),
  },
  {
    name: "neovim_open_files",
    description: "List the files currently open in Neovim (relative to the workspace cwd).",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: () => nvimCall("open_files"),
  },
];

// ---- MCP stdio JSON-RPC plumbing ---------------------------------------------

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function handle(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;

  switch (method) {
    case "initialize": {
      const proto = (params && params.protocolVersion) || DEFAULT_PROTOCOL;
      reply(id, {
        protocolVersion: proto,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
      });
      return;
    }
    case "notifications/initialized":
    case "initialized":
      return; // notification, no response
    case "ping":
      if (isRequest) reply(id, {});
      return;
    case "tools/list": {
      reply(id, {
        tools: TOOLS.map((t) => ({
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        })),
      });
      return;
    }
    case "tools/call": {
      const name = params && params.name;
      const tool = TOOLS.find((t) => t.name === name);
      if (!tool) {
        replyError(id, -32602, `unknown tool: ${name}`);
        return;
      }
      let data;
      try {
        data = tool.run(params.arguments || {});
      } catch (e) {
        data = { ok: false, reason: String(e && e.message ? e.message : e) };
      }
      reply(id, {
        content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
        isError: data && data.ok === false,
      });
      return;
    }
    default:
      if (isRequest) replyError(id, -32601, `method not found: ${method}`);
      return;
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue; // ignore malformed lines
    }
    debug(`recv ${msg.method || "?"} id=${msg.id}`);
    try {
      handle(msg);
    } catch (e) {
      process.stderr.write(`agy-nvim-mcp: handler error: ${e.stack || e}\n`);
    }
  }
});
process.stdin.on("end", () => process.exit(0));
