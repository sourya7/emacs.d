#!/usr/bin/env python3
"""Deterministic offline MCP stdio fixture for PiChat integration tests."""
import json
import sys


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        response = {"jsonrpc": "2.0", "id": request["id"]}
        if method == "initialize":
            response["result"] = {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "pichat-test-mcp", "version": "1"},
            }
        elif method == "tools/list":
            response["result"] = {
                "tools": [
                    {
                        "name": name,
                        "description": "Fixture " + name,
                        "inputSchema": {"type": "object", "properties": {}},
                    }
                    for name in ("search", "other", "alpha-beta", "alpha_beta")
                ]
            }
        elif method == "tools/call":
            response["result"] = {
                "content": [
                    {"type": "text", "text": "CALLED " + request["params"]["name"]}
                ]
            }
        elif method == "resources/list":
            response["result"] = {
                "resources": [{"uri": "fixture://resource", "name": "fixture"}]
            }
        elif method == "resources/templates/list":
            response["result"] = {"resourceTemplates": []}
        elif method == "resources/read":
            response["result"] = {
                "contents": [
                    {
                        "uri": "fixture://resource",
                        "mimeType": "text/plain",
                        "text": "fixture resource",
                    }
                ]
            }
        else:
            response["error"] = {"code": -32601, "message": "Unknown method"}
        reply(response)
    except Exception as error:
        print(repr(error), file=sys.stderr, flush=True)
