#!/usr/bin/env python3
"""Privacy guard for Lovely's Gmail access (per-endpoint allowlist).

Approved 2026-11-01: gmail.modify for Trash and Done.
Approved 2026-11-04 (Sprint 6): filters, sending and Lovely/ labels, only in GmailActions.swift,
each behind a ConfirmedAction made by the preview sheet. Forwarding addresses are read only (GET); Gmail's create call
works only for Workspace service accounts, and the owner adds addresses in Gmail's own Settings.
Never allowed: permanent delete, the full-access scope, other Gmail settings.

  check     Scan App/Reelmail and fail on any violation.
  selftest  Prove the rules catch bad code and pass good code (no Xcode needed).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "App" / "Reelmail"
ACTIONS = "Gmail/GmailActions.swift"
SERVICE = "Gmail/GmailService.swift"
CONFIG = "Gmail/GmailConfig.swift"
SHEET = "Features/Actions/ActionPreviewSheet.swift"
GUARDS = "Gmail/ActionGuards.swift"

# Helpers in GmailActions.swift that do not change anything by themselves.
HELPERS = {"request", "call", "deliver", "encode", "init"}
# Read-only functions in GmailActions.swift: no ConfirmedAction, and every call in them must be a GET.
READ_ONLY = {"forwardingStatus"}


def strip_comments(text):
    return "\n".join(re.sub(r"(?<!:)//.*$", "", line) for line in text.splitlines())


def check(files):
    """files: {relative path: text}. Returns a list of violation strings."""
    bad = []
    for rel, raw in files.items():
        text = strip_comments(raw)
        def hit(pattern, message, allowed=()):
            if rel in allowed:
                return
            for m in re.finditer(pattern, text):
                line = text[: m.start()].count("\n") + 1
                bad.append(f"{rel}:{line}: {message}")

        hit(r"batchDelete|batchModify", "Batch delete or batch modify is never allowed.")
        hit(r'https://mail\.google\.com/["\s]', "The full-access Gmail scope is never allowed.")
        hit(r"/settings/(vacation|imap|pop|delegates|autoForwarding|sendAs|cse|language)", "Only filters and forwarding addresses may be changed in Gmail settings.")
        hit(r'"DELETE"', "DELETE is allowed only in GmailActions.swift (for filters Lovely made).", allowed=(ACTIONS,))
        hit(r"/messages/send|/settings/filters|/settings/forwardingAddresses|/labels|/drafts", "This Gmail endpoint may be used only in GmailActions.swift.", allowed=(ACTIONS,))
        hit(r"/modify\b", "The modify endpoint may be used only in GmailService.swift and GmailActions.swift.", allowed=(SERVICE, ACTIONS))
        hit(r"gmail\.(modify|send|settings\.basic|settings\.sharing|compose|readonly)", "Gmail scopes may be named only in GmailConfig.swift.", allowed=(CONFIG,))
        hit(r"ConfirmedAction\(|ConfirmedAction\.init|\.init\(preview:", "ConfirmedAction may be made only by the preview sheet.", allowed=(SHEET, GUARDS))
        hit(r"googleapis\.com/auth/", "OAuth scopes may be named only in GmailConfig.swift.", allowed=(CONFIG,))
        hit(r"(?<![\w.])gmail\.(labels|metadata|insert|addons|settings)", "Gmail scopes may be named only in GmailConfig.swift.", allowed=(CONFIG,))
        hit(r"gmail\.googleapis\.com", "The Gmail API may be called only from GmailService.swift and GmailActions.swift.", allowed=(SERVICE, ACTIONS))
        hit(r"/messages/(import|insert)|/import\b|/insert\b|/settings/forwarding\b|/stop\b|/watch\b", "Importing, inserting, auto-forwarding and push watch are never allowed.")
        hit(r'"(send|labels|filters|forwardingAddresses|settings|drafts)"', "Gmail endpoint names may appear only in GmailActions.swift.", allowed=(ACTIONS,))
        if rel != ACTIONS:
            for m in re.finditer(r"LabelIds", text):
                window = text[m.start(): m.start() + 40]
                if not re.match(r'LabelIds\\?"?\s*:\s*\[\\?"UNREAD\\?"\]', window):
                    bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: Outside GmailActions.swift only the UNREAD label may change.")
        else:
            for m in re.finditer(r"removeLabelIds[^\n]*", text):
                if '["INBOX"]' not in m.group(0):
                    bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: removeLabelIds may remove INBOX only.")
            for m in re.finditer(r'"DELETE"[^\n]*', text):
                pass
            for m in re.finditer(r"call\(\"DELETE\",\s*\"([^\"]*)", text):
                if "/settings/filters/" not in m.group(1):
                    bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: DELETE may remove filters only.")
            for m in re.finditer(r'call\("(\w+)",\s*"/settings/forwardingAddresses', text):
                if m.group(1) != "GET":
                    bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: Forwarding addresses may only be read (GET).")
            # Every changing function takes a ConfirmedAction.
            for m in re.finditer(r"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\(([^{]*)\{", text, re.S):
                name, signature = m.group(1), m.group(2)
                if name in HELPERS:
                    continue
                if name in READ_ONLY:
                    nxt = re.search(r"\n\s*(?:private\s+)?(?:func|struct|// MARK)\b", text[m.end():])
                    body = text[m.end(): m.end() + nxt.start()] if nxt else text[m.end():]
                    for c in re.finditer(r'call\("(\w+)"', body):
                        if c.group(1) != "GET":
                            bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: func {name} is read-only and may only GET.")
                    continue
                if "ConfirmedAction" not in signature:
                    bad.append(f"{rel}:{text[: m.start()].count(chr(10)) + 1}: func {name} must take a ConfirmedAction.")
    return bad


def load():
    files = {}
    for p in SRC.rglob("*.swift"):
        files[p.relative_to(SRC).as_posix()] = p.read_text()
    return files


def selftest():
    good_actions = '''
struct GmailActions {
    func ensureLabel(_ name: String, confirmed: ConfirmedAction) async throws -> String { "" }
    func deleteFilter(id: String, confirmed: ConfirmedAction) async throws { try await call("DELETE", "/settings/filters/x") }
    func file(messageID: String, confirmed: ConfirmedAction) async throws { body["removeLabelIds"] = ["INBOX"] ; call("POST", "/messages/x/modify") }
    func request(_ method: String) throws -> Int { 0 }
    func forwardingStatus() async throws -> [Int] { let l: L = try await call("GET", "/settings/forwardingAddresses"); return [] }
}
'''
    ok = {ACTIONS: good_actions, SERVICE: 'path = "/modify"; json = "{\\"addLabelIds\\":[\\"UNREAD\\"]}"', CONFIG: 'let modify = "https://www.googleapis.com/auth/gmail.modify"'}
    assert check(ok) == [], check(ok)
    cases = {
        "send outside actions": {"Model/X.swift": 'let u = "/messages/send"'},
        "batch delete": {"Model/X.swift": 'let u = "batchDelete"'},
        "full access scope": {"Model/X.swift": 'let s = "https://mail.google.com/"'},
        "vacation settings": {ACTIONS: good_actions, "Model/X.swift": 'let u = "/settings/vacation"'},
        "delete outside actions": {"Model/X.swift": 'm = "DELETE"'},
        "scope outside config": {"Model/X.swift": 'let s = "gmail.send"'},
        "label other than unread": {SERVICE: '{"addLabelIds":["STARRED"]}'},
        "confirmed made elsewhere": {"Model/X.swift": "let c = ConfirmedAction(preview: p)"},
        "unconfirmed changing func": {ACTIONS: good_actions + "\nstruct Y { func sendNow(to: String) async throws {} }"},
        "remove label other than inbox": {ACTIONS: good_actions.replace('["INBOX"]', '["UNREAD"]')},
        "delete message in actions": {ACTIONS: good_actions.replace("/settings/filters/x", "/messages/x")},
        "confirmed via init": {"Model/X.swift": "let c: ConfirmedAction = .init(preview: p)"},
        "other scope": {"Model/X.swift": 'let s = "https://www.googleapis.com/auth/gmail.labels"'},
        "api from elsewhere": {"Model/X.swift": 'let u = "https://gmail.googleapis.com/gmail/v1/users/me/messages"'},
        "insert message": {"Model/X.swift": 'let u = base + "/messages/insert"'},
        "auto forwarding": {ACTIONS: good_actions + '\nlet u = "/settings/forwarding"'},
        "forwarding address create": {ACTIONS: good_actions.replace('call("GET", "/settings/forwardingAddresses")', 'call("POST", "/settings/forwardingAddresses")')},
        "read-only func that writes": {ACTIONS: good_actions.replace('call("GET", "/settings/forwardingAddresses")', 'call("POST", "/settings/filters")')},
        "unconfirmed forwarding create": {ACTIONS: good_actions + '\nstruct Z { func addForwarding() async throws { call("GET", "/settings/forwardingAddresses") } }'},
        "endpoint built from parts": {"Model/X.swift": 'let u = "/messages/" + "send"'},
    }
    for name, files in cases.items():
        assert check(files), f"guard missed: {name}"
    # Comments never trip the guard.
    assert check({"Model/X.swift": "// we never call /messages/send here"}) == []
    print("privacy_guard selftest: ok")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "selftest":
        selftest()
    elif cmd == "check":
        problems = check(load())
        for p in problems:
            print(f"::error::{p}")
        if problems:
            sys.exit(1)
        print("privacy_guard: ok")
    else:
        sys.exit("usage: privacy_guard.py check|selftest")
