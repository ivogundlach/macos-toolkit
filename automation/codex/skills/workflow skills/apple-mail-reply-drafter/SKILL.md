---
name: apple-mail-reply-drafter
description: >-
  Use when Ivo asks to draft, write, prepare, or create an email in Apple Mail,
  whether it is a reply in an existing thread or a new standalone message.
  Trigger on phrases like "draft a reply", "reply to this email", "make an
  Apple Mail draft", "draft an email to X", or "answer the email from X".
  Orchestrates local-read-connectors and ivo-writer, preserves the correct
  sender/recipient/thread when applicable, and creates a saved background draft.
  Hidden creation is the default. The tested Mail attachment-menu fallback may
  foreground Mail and therefore requires explicit foreground permission. Never send mail.
---

# Apple Mail Drafter

Create Apple Mail drafts silently in the background. Preserve sender account, recipient, and thread context for replies; support standalone messages when no source thread exists. This is an orchestration skill, not a writing-style skill and not a local-data connector.

## Related Skills

- Use `local-read-connectors` to find Apple Mail metadata and read message bodies when needed.
- Use `ivo-writer` for the human-facing reply text.
- Use `computer-use` only for the explicitly authorized foreground attachment fallback below.
- Use `codex-claude-sync-check` only after this skill itself is edited and mirrors need verification.

## Hard Rules

- Never send. This skill creates saved drafts only.
- Always create and save drafts in the background when the helper can complete the requested work. Hidden creation is the default.
- On the macOS/Mail setup observed on 2026-08-02, opening the saved draft and using Mail's Attach menu/file chooser foregrounded Mail. Never describe that tested route as background-safe or claim that the previously focused app stayed focused.
- Put only recipient-facing email text in the body. Never insert internal labels or review notices such as `[Codex draft - review before sending]`.
- Use the deterministic helper for draft creation; do not improvise a one-off AppleScript.
- Prefer an existing Apple Mail reply draft in the original thread over a new standalone outgoing message.
- Preserve both sides of the thread: use the original recipient address and the actual sender account/address that received the message.
- Read the available Apple Mail conversation within the context gate before writing a reply, including Ivo's sent messages and messages in Trash/deleted mailboxes. Only permanently purged or gate-omitted mail is unavailable.
- Limit automatic thread context to the newest 20 messages from the preceding 180 days and 60,000 characters. Always retain the latest incoming message and remove the oldest context first.
- Do not guess recipient or sender accounts. If the thread match is ambiguous, ask Ivo to choose by sender, subject, date, and mailbox.
- Do not manually add `Ivo` as a sign-off; Apple Mail inserts Ivo's signature.
- Attach only files Ivo explicitly supplied or approved for that message. Never glob Downloads, infer evidence files from nearby filenames, or attach unrelated local material.
- If an approved path is missing, do not silently recover, copy, or restore a same-named file from Trash or another directory. Report the found location and obtain explicit permission before changing its location or attaching that substitute path.
- When the request declares supporting files, include every declared file or stop and identify the missing path. If the body appears to mention an attachment but no file was supplied or approved, warn instead of guessing.
- Never report that attachments were added merely because the helper returned `status: drafted`. Verify the persisted Drafts message independently and list attached and missing filenames in the result.
- If Mail cannot materialize an attachment while the composer remains hidden, stop after the first failed attempt. Do not retry, create a duplicate draft, or switch to `visible:true`; verify the persisted attachment state, identify the exact missing file, and request explicit permission for the bounded foreground compose fallback if Ivo still wants the agent to finish it.
- Do not draft for no-reply, newsletter, receipt, invoice, verification-code, automated, or uncertain sender classifications unless Ivo explicitly overrides.
- Interactive draft creation never deletes mail. The existing scheduled `clean-junk` pass is separate: only inside Junk/Spam mailboxes, it automatically deletes explicit-spam-header messages, blank/no-meaningful-text messages, and advertisement-plus-unsubscribe messages. It marks every such message read before deletion. Anything plausibly real stays for review.
- A Junk message carrying an `In-Reply-To` or `References` header is never deleted, whatever the spam headers say: threading is evidence Ivo started the conversation, while a spam flag is only a third-party guess. Such messages are always escalated to the Inbox with reason `protected-reply-to-sent-mail:*`. Losing real correspondence is the expensive error here; one extra message in the Inbox is the cheap one, so any future junk rule must keep this asymmetry.
- Background draft generation uses the established workflow-specific model choice, GPT-5.6 Terra with medium reasoning. No global model substitution applies.

## Config

Read `config/defaults.json` for helper paths and default scan limits.

## Workflow

1. **Choose reply or standalone mode.**
   - If the request refers to an existing message or thread, use reply mode and continue below.
   - If the request is a new message, resolve the exact sender and recipient, draft the text, then use the standalone command in step 5.

2. **Find the source message for replies.**
   - If Ivo gives a row id, use it directly.
   - Otherwise use `local-read-connectors` Apple Mail search first:

```bash
/Users/YOUR_USERNAME/.local/share/codex-connectors/codex-read mail-search "QUERY" --days 90 --limit 10
```

3. **Disambiguate only when needed.**
   - One high-confidence match: continue.
   - Several plausible matches: use an AskUserQuestion-style prompt if the current surface supports it; otherwise ask one plain-English question listing sender, subject, date, and mailbox.
   - No match: broaden the query once, then ask Ivo for a better clue.

4. **Read the bounded thread for replies.**
   - Read available messages in Apple Mail's conversation, in chronological order, including Sent, Archive, Trash, and messages flagged deleted.
   - Apply all three usage gates: newest 20 messages, preceding 180 days, and 60,000 serialized characters. Always retain the latest incoming message; omit oldest context first and surface the omission count to the drafting model.
   - Include participants, dates, attachment names, and both sides' message bodies. Use prior replies to preserve commitments and avoid asking for information already supplied.
   - For assistant-scan candidates, use the structured `thread` returned by the helper.
   - For a known Apple Mail row id when no scan context is available:

```bash
/Users/YOUR_USERNAME/.local/bin/apple-mail-rowid-body --json ROW_ID
```

   - Do not print full private bodies back to chat unless Ivo asked to see them.

5. **Draft the message with `ivo-writer`, then create it in Apple Mail.**
   - Preserve facts, dates, names, identifiers, deadlines, and every user-specified ask.
   - Before drafting, declare `Target language: <language> (<evidence>)` in user-visible commentary; Ivo's instruction language is not evidence unless he explicitly names the draft language; unresolved or conflicting evidence requires asking before draft creation; verify the full human-authored text before creation; follow `ivo-writer`'s `references/correspondence.md` target-language gate for details.
   - Keep the reply short unless the situation requires context.
   - No manual `Ivo` signature.
   - Before drafting, make an explicit attachment inventory from only the files Ivo supplied or approved. Require each file to exist, be readable, regular, and nonempty. The helper warns above 10 MB encoded total and rejects more than 20 MB.

   **Reply draft:**

   - Prefer the existing helper for thread-preserving drafts:

```bash
/Users/YOUR_USERNAME/.local/bin/apple-mail-draft-assistant create-draft --payload -
```

   - Payload shape:

```json
{
  "state_key": "STATE_KEY_FROM_SCAN_OR_THREAD_CONTEXT",
  "mail_id": 12345,
  "reply_from": "required configured sender/account address from source message",
  "account_name": "optional exact Apple Mail account for a non-Inbox source",
  "mailbox_name": "optional exact Apple Mail mailbox for a non-Inbox source",
  "operation_id": "optional caller-generated UUID for idempotent retry",
  "body": "Draft body from ivo-writer, without manual Ivo signature",
  "attachments": ["/absolute/path/to/explicitly-approved-file.pdf"]
}
```

   - Required fields are `state_key`, `mail_id`, `reply_from`, and `body`. `attachments` is optional and must contain only explicitly approved absolute paths. For a non-Inbox source, supply both `account_name` and `mailbox_name`; the helper refuses a half-scoped source. `operation_id` is optional for a one-shot interactive call and required when a caller may retry.
   - `reply_from` must match a configured Apple Mail account address; the helper refuses to let Mail choose a default sender.
   - **Hard gate before `create-draft`:** resolve `reply_from` (the account address the original mail was *delivered to*) and the recipient from the source message itself. If either cannot be resolved from the message, STOP and ask — never substitute a different one of Ivo's addresses (past failure: university address used when the mail went to iCloud). Echo both addresses in the final response.

   **Standalone draft:**

```bash
/Users/YOUR_USERNAME/.local/bin/apple-mail-draft-assistant create-message-draft --payload -
```

   Payload shape:

```json
{
  "to": ["recipient@example.com"],
  "sender": "you@icloud.example.com",
  "subject": "Exact subject",
  "body": "Draft body from ivo-writer, without manual Ivo signature",
  "operation_id": "optional caller-generated UUID for idempotent retry",
  "attachments": ["/absolute/path/to/optional-file.pdf"]
}
```

   - Required fields are `to`, `sender`, `subject`, and `body`; `attachments` and `operation_id` are optional. Supply the same `operation_id` when a caller may retry.
   - Resolve the sender and recipient before creation. Never let Mail choose a default account.
   - The helper creates the message with `visible:false` and does not activate Mail.

6. **Verify outcome.**
   - Confirm the helper returned `status: drafted`.
   - If attachments were requested, search for the exact saved draft, resolve its Apple Mail row id, and run:

```bash
python3 "/Users/YOUR_USERNAME/.codex/skills/workflow skills/apple-mail-reply-drafter/scripts/verify-draft-attachments.py" \
  --rowid ROW_ID \
  --expect "/absolute/path/to/explicitly-approved-file.pdf" \
  --from-address "sender@example.com" \
  --to-address "recipient@example.com" \
  --subject "Exact subject"
```

   - Treat only `status: verified` as attachment success. An Apple attachment placeholder, missing MIME/file bytes, an address/subject mismatch, or verifier error means the draft is incomplete; do not tell Ivo it is ready to send. Apple Mail may persist image attachments with `Content-Disposition: inline`; accept that for image files only when the verifier confirms the exact filename and bytes and the compose inspection showed the image. Do not generalize this exception to non-image files.
   - If creation fails after Mail save begins, the helper records `failed-permanent` with `phase: manual-review`; do not retry automatically because the save result may be ambiguous.

7. **Use the foreground attachment fallback only after explicit authorization.**
   - This fallback is permitted only after the hidden attachment attempt fails and Ivo gives direct, unambiguous permission in the current conversation for this bounded foreground sequence. Permission is required before opening the saved draft because that action may itself foreground Mail.
   - The authorized sequence is limited to opening the exact saved draft, opening Attach Files, selecting the exact approved file, confirming that attachment, saving, and closing the draft. Permission expires immediately after persisted verification; every corrective retry requires fresh permission.
   - Load `computer-use`. Open or reuse only the exact draft after matching sender, recipient, and subject. Expect the tested Attach-menu/file-chooser route to foreground Mail; do not claim otherwise.
   - Attach only the previously approved inventory. Before choosing a file, match its exact absolute path or exact filename in the approved directory; never select a nearby file by position alone.
   - Never invoke the Send or Send Later controls. After the attachment is visibly present, save the draft and close the compose window. If closing presents the expected save prompt, choose Save only; never choose Send.
   - If any unexpected dialog or state appears, stop without clicking Send, Send Later, Discard, or another destructive control. Preserve the unsent draft and identify the smallest Ivo-only cleanup step.
   - Re-run the persisted-draft verifier from step 6. Report success only when it returns `status: verified` and the compose window is closed. If verification fails, stop and report the incomplete draft; do not reopen Mail without fresh foreground permission.
   - Without foreground permission, preserve the unsent draft, verify whether the requested file is absent, present, or only a placeholder, and ask Ivo either to attach it manually or authorize the bounded sequence. Do not remove or retry an ambiguous attachment.

## Existing Assistant Scan

For inbox-style tasks where Ivo asks to draft replies to current messages, use the existing assistant scan instead of manually searching:

```bash
/Users/YOUR_USERNAME/.local/bin/apple-mail-draft-assistant scan --json --limit 20 --max-age-days 14
```

The scan returns candidate records with `state_key`, `mail_id`, sender fields, subject, latest body, `reply_from`, and a bounded chronological `thread` containing available messages from every mailbox, including Trash/deleted mail. Use that thread plus its truncation metadata when drafting with `ivo-writer`.

## Output

Keep the response short:

- `Draft created`: yes/no.
- `Thread`: sender and subject.
- `Sender account preserved`: yes/no/unknown.
- `Attachments verified`: exact filenames, `none`, or `no` with the missing filenames.
- `Notes`: only ambiguity, missing context, or helper error.
