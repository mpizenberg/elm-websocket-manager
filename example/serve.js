// Static file server for the example.
// Serves example/ as root and maps /js/ to ../js/ so the package JS module resolves.
// Usage: node serve.js

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname } from "node:path";

const exampleDir = import.meta.dirname;
const projectDir = resolve(exampleDir, "..");
const port = 3000;

const mimeTypes = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".json": "application/json",
};

createServer(async (req, res) => {
  const url = req.url === "/" ? "/index.html" : req.url;

  // Map /js/* to the package's ../js/ directory
  const filePath = url.startsWith("/js/")
    ? resolve(projectDir, "." + url)
    : resolve(exampleDir, "." + url);

  if (!filePath.startsWith(projectDir)) {
    res.writeHead(403);
    res.end();
    return;
  }
  try {
    const data = await readFile(filePath);
    const mime = mimeTypes[extname(filePath)] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": mime });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
}).listen(port, () => {
  console.log(`Serving at http://localhost:${port}`);
});
