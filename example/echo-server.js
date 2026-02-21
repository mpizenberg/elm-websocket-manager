// Minimal WebSocket echo server for testing the example.
// Usage: node echo-server.js
// Requires the `ws` package (npm install).

import { WebSocketServer } from "ws";

const port = 8080;
const wss = new WebSocketServer({ port });

wss.on("connection", (ws) => {
  console.log("Client connected");

  ws.on("message", (data) => {
    const msg = data.toString();
    console.log("Received:", msg);
    ws.send(msg);
  });

  ws.on("close", (code, reason) => {
    console.log(`Client disconnected (code: ${code})`);
  });
});

console.log(`Echo server listening on ws://localhost:${port}`);
