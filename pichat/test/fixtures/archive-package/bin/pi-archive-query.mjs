#!/usr/bin/env node
import os from "node:os";
import path from "node:path";

const command = process.argv[2];
const metadata = {
  sessionId: "archive-child",
  sessionFile: "/fixture/sessions/archive-child.jsonl",
  cwd: "/fixture/project",
  sessionName: null,
  firstUserPrompt: "Inspect archive relations",
  branchFirstUserPrompt: "Continue archive child work",
  title: "Inspect archive relations",
  displayTitle: "Continue archive child work",
  createdAt: "2026-01-01T00:00:00.000Z",
  latestActivityAt: "2026-01-01T01:00:00.000Z",
  sourceExists: true,
  syncStatus: "current",
  parentSessionPath: "/fixture/sessions/archive-parent.jsonl",
  parentSessionId: "archive-parent",
  parentResolution: "resolved",
  childCount: 0,
};
const parent = {
  ...metadata,
  sessionId: "archive-parent",
  sessionFile: "/fixture/sessions/archive-parent.jsonl",
  sessionName: "Archive parent",
  branchFirstUserPrompt: null,
  title: "Archive parent",
  displayTitle: "Archive parent",
  parentSessionPath: null,
  parentSessionId: null,
  parentResolution: "none",
  childCount: 1,
};
const write = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

switch (command) {
  case "status":
    write({
      queryProtocolVersion: 1,
      schemaVersion: 3,
      stableApiVersion: 1,
      searchPolicyVersion: 1,
      database: path.join(os.homedir(), ".pi", "agent", "archive.db"),
      backfillStatus: "running",
      lastCompleteScanAt: null,
      lastSuccessfulSyncAt: null,
      lastErrorAt: null,
      lastErrorCode: null,
      lastErrorMessage: null,
    });
    break;
  case "projects":
    write({
      cwd: "/fixture/project",
      sessionCount: 2,
      loadableSessionCount: 2,
      latestActivityAt: metadata.latestActivityAt,
    });
    break;
  case "recent":
    write(metadata);
    break;
  case "search":
    write({
      ...metadata,
      matchKind: "content",
      score: 2,
      matchCount: 1,
      entryId: "selected-entry",
      entryRowId: 2,
      entryLoadable: true,
      highlightTerms: ["archive"],
      occurrences: [],
    });
    break;
  case "session":
    write({
      sessionId: metadata.sessionId,
      entryId: "selected-entry",
      entryRowId: 2,
      resultKind: "user",
      role: "user",
      toolName: null,
      timestamp: metadata.latestActivityAt,
      text: "Inspect archive relations",
      entryLoadable: true,
      match: true,
    });
    break;
  case "session-info":
    write({
      ...metadata,
      forkPosition: "at",
      selectedEntryId: "selected-entry",
      sharedBaseEntryId: "selected-entry",
      forkPointStatus: "observed",
    });
    break;
  case "relations":
    write({
      sessionId: metadata.sessionId,
      relatedSession: parent,
      direction: "parent",
      parentReferencePath: metadata.parentSessionPath,
      parentResolution: "resolved",
      forkPosition: "at",
      selectedEntryId: "selected-entry",
      sharedBaseEntryId: "selected-entry",
      forkPointStatus: "observed",
    });
    break;
  default:
    process.stderr.write(
      `${JSON.stringify({ code: "INVALID_ARGUMENT", message: "Unknown fixture operation" })}\n`,
    );
    process.exitCode = 2;
}
