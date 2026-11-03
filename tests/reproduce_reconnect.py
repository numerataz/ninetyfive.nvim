"""Exercise reconnect ordering using Neovim and the bundled WebSocket proxy.

Run from the repository root: python tests/reproduce_reconnect.py
Requires Python's websockets package and nvim on PATH.
"""
import asyncio, json, pathlib, tempfile
import websockets

ROOT = str(pathlib.Path(__file__).resolve().parents[1])
async def main():
    connections = []
    async def handler(ws):
        messages = []
        connections.append(messages)
        try:
            async for raw in ws:
                message = json.loads(raw)
                messages.append(message)
                if len(connections) == 1:
                    await ws.close()
                    return
                if message['type'] in ('file-content', 'file-delta'):
                    return
        except websockets.ConnectionClosed:
            pass
    async with websockets.serve(handler, '127.0.0.1', 0) as server:
        port = server.sockets[0].getsockname()[1]
        lua = f'''
vim.opt.rtp:append({json.dumps(ROOT)})
_G.Ninetyfive = {{ config = {{ debug = false, indexing = {{ mode = "off" }} }} }}
local websocket = require("ninetyfive.websocket")
local communication = require("ninetyfive.communication").new()
communication.mode = "websocket"
websocket.on_reconnect(function() communication:resync_all_buffers() end)
assert(websocket.setup_connection("ws://127.0.0.1:{port}/ws", "test", nil))
local first_job = _G.Ninetyfive.websocket_job
vim.api.nvim_buf_set_lines(0, 0, -1, false, {{ "before" }})
assert(communication:send_file_delta())
assert(vim.wait(5000, function()
    local job = _G.Ninetyfive.websocket_job
    return job and job ~= first_job
end, 5), "did not reconnect")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {{ "after" }})
assert(communication:send_file_delta())
vim.wait(100)
websocket.shutdown()
vim.cmd("qa!")
'''
        with tempfile.NamedTemporaryFile(suffix='.lua', mode='w') as script:
            script.write(lua); script.flush()
            proc = await asyncio.create_subprocess_exec('nvim', '--headless', '-u', 'NONE', '-l', script.name, cwd=ROOT, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            stdout, stderr = await asyncio.wait_for(proc.communicate(), 15)
            if proc.returncode:
                raise RuntimeError(stderr.decode())
        print(json.dumps(connections, indent=2))
        assert len(connections) >= 2, 'missing second connection'
        first = connections[1][0]
        assert first['type'] == 'file-content', 'No active file in file-delta: new connection received ' + first['type']
        assert first['text'] == 'after'
asyncio.run(main())
