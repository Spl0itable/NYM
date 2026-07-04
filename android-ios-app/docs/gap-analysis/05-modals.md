# Gap report 05 — Modals & dialogs (identity, login, vault, nick/profile, new-PM, poll, report, command palette, reactors, translate, generic dialog/toast)

## Summary
Reviewed all 13 modal/dialog surfaces in this slice against the PWA. **Faithful ports** (no
material gaps): command palette, reactors modal, translate language prompt, poll-create modal,
nostr login modal, vault boot-unlock, panic overlay. **Materially incomplete**: New-PM modal
(missing suggestions, the entire group avatar/banner/description/allow-invites section, and the
initial-message field), Setup modal (avatar/banner are URL inputs, not file pickers; no char
counters), Nick/profile edit (no Randomize button, no pubkey slideout, no nsec Copy button, and
**does not pre-fill bio/lightning — will silently blank them on save**), Report modal (**submit
is a no-op stub — reports never publish**). Cross-cutting: there is **no centralized
dialog/confirm/prompt component** (PWA's `showAppConfirm/Alert/Prompt`, 33 call sites) and **no
toast/snackbar design system** — Flutter uses ad-hoc `AlertDialog`/`SnackBar`/`showDialog` per
site. Two vault sub-flows are missing (cross-device "encrypt here too?" prompt; `_vaultReauth`).
The developer "Reserved Nickname" (devNsec) verification modal is entirely absent.

**Count: 14 findings** — 1 blocker, 5 high, 5 medium, 3 low. (Plus 1 incidental.)

Note: settings/shop/zap/call modals are explicitly owned by other agents and were not audited
here, even where they appear adjacent in `index.html`.

---

### F1: Report modal submit is a no-op — reports are never published  [SEVERITY: blocker]
- PWA: `js/modules/ui-context.js:312-352` (`submitReport`) builds a NIP-56 kind-1984 event
  `{kind:1984, created_at, tags:[['p',pubkey,reportType], (['e',messageId,reportType] if "report
  message" checked)], content:details, pubkey}`, signs it, `sendToRelay(["EVENT", signed])`, then
  `displaySystemMessage('Report submitted successfully')` + closes. Markup `index.html:361-405`.
- Flutter: `lib/widgets/context_menu/report_modal.dart:174-183` — "Submit Report" calls
  `widget.onSubmit?.call(type, details, reportMessage)` then pops. But the only caller,
  `lib/widgets/context_menu/context_menu_panel.dart:359-363`, invokes `ReportModal.show(context,
  targetNym:…, hasMessage:…)` **without passing `onSubmit`**, so the callback is null. There is no
  kind-1984 publish anywhere in `lib/` (the constant `EventKinds.report = 1984` at
  `lib/core/constants/event_kinds.dart:29` is unused).
- Gap: The whole Report flow is dead. A user fills out the form, taps Submit, the dialog closes,
  and nothing is signed or sent — no event, no confirmation, no error. User-visible: reporting
  silently does nothing.
- Fix approach: Add `Future<void> publishReport({required String pubkey, String? messageId,
  required String type, required String details, required bool reportMessage})` to
  `NostrController` (build the event exactly as ui-context.js:324-338, sign via the existing
  signer path, publish via the relay-send path used by `publishPoll`). Wire it in
  `context_menu_panel.dart` by passing `onSubmit: (type, details, reportMsg) =>
  controller.publishReport(pubkey: t.pubkey, messageId: reportMessage ? t.messageId : null, …)`.
  On success show a SnackBar "Report submitted successfully" (PWA `displaySystemMessage`), on
  failure "Failed to submit report".
- Effort: M  Risk: low  Confidence: high

---

### F2: New-PM modal missing group avatar/banner/description/allow-invites section  [SEVERITY: high]
- PWA: `index.html:319-347` — when ≥2 recipients are chosen the modal reveals a full
  group-creation block: **Group Avatar & Banner** uploaders (`newGroupMediaGroup`,
  `newGroupBannerPreview` + `newGroupAvatarPreview`, file inputs, `newGroupUploadProgress` bar),
  **Description** textarea (`newGroupDescInput`, maxlength 150, char count `newGroupDescCharCount`
  `0/150`), and an **"Allow members to add others"** checkbox (`newGroupAllowInvites`, checked by
  default; hint "When off, only you (the group owner) can add new members.").
- Flutter: `lib/features/pms/new_pm_modal.dart:202-215` — group mode adds ONLY a Group Name field
  (and no visible char counter — `counterText:''` at :213). No avatar/banner, no description, no
  allow-invites toggle.
- Gap: Creating a group from this modal cannot set an avatar, banner, description, or the
  members-can-add-others permission. The group is created bare; `createGroup(name, pubkeys)` at
  :111-114 passes none of these.
- Fix approach: In `_NewPmModalState`, gate a group-media section behind `_groupMode`: two
  `image_picker` tiles (reuse the avatar/banner pattern from `nick_edit_modal.dart:245-324`), a
  Description `TextField` (maxLength 150 with a `0/150` counter), and a `SwitchListTile`/`Checkbox`
  "Allow members to add others" (default true). Extend `NostrController.createGroup` to accept
  `{avatar, banner, description, allowInvites}` and thread them through.
- Effort: L  Risk: med  Confidence: high

---

### F3: New-PM modal missing initial-message field  [SEVERITY: high]
- PWA: `index.html:348-351` — "Message (optional)" textarea `pmInitialMessage` ("Start the
  conversation..."); on Start the typed text is sent as the first DM/group message.
- Flutter: `lib/features/pms/new_pm_modal.dart` — no message field anywhere; `_start()` (:101-117)
  only calls `startPM` / `createGroup` and pops.
- Gap: User cannot seed the first message when starting a PM/group; they must open the empty
  thread and type separately. Differs from PWA where a one-shot "say hi" is built into the flow.
- Fix approach: Add a multiline `TextField` ("Start the conversation...") below the recipient/group
  fields. In `_start`, after `startPM`/`createGroup` returns the conversation target, send the
  trimmed text through the controller's send path (the PWA routes it via the same send used by the
  composer once the PM is opened).
- Effort: M  Risk: med  Confidence: high

---

### F4: New-PM modal missing live recipient suggestions dropdown  [SEVERITY: high]
- PWA: `index.html:304-312` + `pms.js` `onNewPMRecipientInput` — typing in the recipient box shows
  a `pmSuggestions` dropdown of matching nyms (search-as-you-type); clicking a suggestion adds a
  chip. Empty box state + paste both handled.
- Flutter: `lib/features/pms/new_pm_modal.dart:188-201` — a single TextField with an "Add" suffix
  button. `resolveRecipientPubkey` (:23-46) only resolves a fully-typed/pasted token (hex / npub /
  exact nym match) on Enter or Add. There is no incremental suggestion list.
- Gap: User must already know and type the exact nym (or paste a pubkey). No discovery/autocomplete
  of known users — a clear regression from the PWA's searchable picker.
- Fix approach: Below the recipient field render a suggestions list filtered from
  `usersProvider` by the current input (prefix/substring on `nym`, like the channel autocomplete).
  Tapping a row calls the existing add-chip path. Reuse the autocomplete dropdown styling already
  used for mentions.
- Effort: M  Risk: low  Confidence: high

---

### F5: Nick/profile edit does not pre-fill bio & lightning → silently blanks them on save  [SEVERITY: high]
- PWA: `js/app.js:2595-2605` (`editNick`) pre-fills the editor from the current profile:
  `nickEditBioInput.value = nym.getBio(nym.pubkey)` and `nickEditLightningInput.value =
  nym.lightningAddress || ''` (and the avatar preview). Save (`changeNick`, ~:2663-2667) only
  writes a field when it actually changed.
- Flutter: `lib/features/identity/nick_edit_modal.dart:56-57` — `_bio` and `_lightning` controllers
  are created EMPTY and never loaded from the controller's identity/profile. Only the nick name is
  seeded (:53-55). Save (:580-590) sends `about: _bio.text.trim()` and `lud16:
  _lightning.text…` unconditionally.
- Gap: Opening the editor shows a blank Bio and blank Lightning even for users who have them set.
  Because save passes the empty string for `about`, tapping "Change" can wipe an existing bio
  (and, depending on engine semantics, the lightning address). This is a data-loss UX bug, not
  just a cosmetic miss.
- Fix approach: In `initState` (or `didChangeDependencies`), load the current bio / lightning /
  avatar URL from the controller (the values backing `nym.getBio` / `lightningAddress` /
  `nym_avatar_url`) into the controllers and the avatar preview. In `_save`, only send fields that
  changed (mirror changeNick), or at minimum pass `about: null` when the field is untouched.
- Effort: S  Risk: low  Confidence: high

---

### F6: No centralized confirm/alert/prompt dialog component  [SEVERITY: medium]
- PWA: `js/modules/dialog.js` exposes `showAppConfirm` / `showAppAlert` / `showAppPrompt`
  (window-level), used at **33 call sites** (24 confirm / 6 alert / 3 prompt). One styled
  `.app-dialog` component (`index.html` built dynamically; CSS `styles-components.css:2349-2378`):
  `z-index:10003`, `max-width:440px`, message `font-size:14px; line-height:1.45; white-space:
  pre-line`, optional checkbox row, optional single-line input OR `min-height:110px` textarea,
  optional char counter (warning at 80%, limit at 100%), `danger` OK button
  (`styles-components.css:2380-2388`: `bg rgb(danger/.1)`, `border rgb(danger/.35)`, text
  `--danger`), Esc=cancel / Enter=confirm. Confirm resolves bool; with `checkboxLabel` resolves
  `{confirmed, checked}`; prompt resolves the string or null.
- Flutter: No equivalent. `lib/features/identity/vault_boot_unlock.dart:134-161` hand-rolls an
  `AlertDialog` for "Forget identity"; other sites use raw `showDialog`/`AlertDialog`/`SnackBar`
  with locally-defined styling. No shared component, so confirm/alert/prompt look and behave
  inconsistently across modals and don't match `.app-dialog`.
- Gap: Inconsistent confirm/alert styling vs the PWA; no reusable danger-confirm, no prompt-with-
  char-count, no checkbox-confirm. Each new confirmation re-implements the chrome.
- Fix approach: Add `lib/widgets/common/app_dialog.dart` with `Future<bool> showAppConfirm(ctx,
  message, {title, okLabel, cancelLabel, danger, checkboxLabel})`, `Future<void> showAppAlert(...)`,
  `Future<String?> showAppPrompt(... {defaultValue, placeholder, maxLength, multiline})` matching
  the CSS above (440px max width, 14px/1.45 message, danger button colors, char counter, Enter/Esc
  handling). Migrate existing ad-hoc confirms to it.
- Effort: M  Risk: low  Confidence: high

---

### F7: Setup modal — avatar/banner are URL text fields, not file pickers (no preview/spinner/remove)  [SEVERITY: medium]
- PWA: `index.html:1285-1323` — "Choose Your Avatar" and "Choose Your Banner" are full upload
  controls: 80×80 preview (`setupAvatarPreview`), upload spinner (`setupAvatarSpinner`),
  "Choose photo"/"Remove" buttons, status line (`setupAvatarStatus`), banner preview wrap with
  "No banner set" placeholder + spinner. File is uploaded and hosted, URL persisted.
- Flutter: `lib/features/identity/setup_modal.dart:160-168` — plain URL `TextField`s ("Image URL
  (optional)", "Banner URL (optional)"). Self-acknowledged TODO at :18-20. No file picker, no
  preview, no spinner, no Remove.
- Gap: First-run users can't pick a photo from their device for avatar/banner; they must paste a
  hosted URL, which most users won't have. Major friction vs PWA. (Note: `nick_edit_modal.dart`
  DOES use `image_picker` — the setup flow is the outlier.)
- Fix approach: Reuse the `_pickImage`/preview/Remove pattern from `nick_edit_modal.dart:245-324,
  559-574` for both avatar and banner in setup. Pipe the picked file through the same upload→URL
  path the engine uses, persisting to `nym_avatar_url`/`nym_banner_url`.
- Effort: M  Risk: med  Confidence: high

---

### F8: Nick/profile edit missing "Randomize" button  [SEVERITY: medium]
- PWA: `index.html:1248-1252` — modal-actions has THREE buttons: **Randomize** (`randomizeNick`,
  `js/app.js:2721`), Cancel, Change. Randomize generates a fresh random nym in-place.
- Flutter: `lib/features/identity/nick_edit_modal.dart:505-533` (`_actions`) — only Cancel +
  Change.
- Gap: User can't roll a new random nickname from the editor (a one-tap affordance in the PWA).
- Fix approach: Add a left-aligned text/icon button "Randomize" in `_actions` that fills `_nick`
  with a freshly generated random nym (use the same generator the ephemeral-identity boot uses).
- Effort: S  Risk: low  Confidence: high

---

### F9: Nick/profile edit missing pubkey slideout (full hex + explanation + Copy)  [SEVERITY: medium]
- PWA: `index.html:1159-1169` — the `#xxxx` suffix is clickable (`nym-suffix-clickable`, title
  "Click to view full pubkey") and opens a `pubkeySlideout` panel showing "Full Hex Pubkey", an
  explanatory paragraph about keypairs, the full pubkey value (`pubkeySlideoutValue`), and a Copy
  button (`pubkeySlideoutCopy`).
- Flutter: `lib/features/identity/nick_edit_modal.dart:218-227` — the suffix is rendered as static,
  non-interactive monospace text. No slideout, no full-pubkey reveal, no copy.
- Gap: User can't view or copy their full hex pubkey from the editor (a documented affordance in
  the PWA, important for sharing identity).
- Fix approach: Make the suffix tappable; on tap expand an inline panel (like `_revealPrivkeyGroup`
  at :386-450) with the full `_pubkey`, the explanatory copy from the PWA, and a Copy button
  (`Clipboard.setData`).
- Effort: S  Risk: low  Confidence: high

---

### F10: "Reserved Nickname" (developer nsec) verification modal missing entirely  [SEVERITY: medium]
- PWA: `index.html:995-1014` (`devNsecModal`) + `cancelDevNsec`/`verifyDevNsec` — when a user picks
  a reserved nickname ("Luxas" is the developer handle) the app shows a "Reserved Nickname" modal:
  message "\"Luxas\" is reserved for the Nymchat developer.", a password input for the nsec
  (`devNsecInput`, placeholder "nsec1..."), an error line ("Invalid nsec - does not match the
  developer pubkey."), and Cancel/Verify actions. Verifies the pasted nsec maps to the developer
  pubkey before allowing the name.
- Flutter: MISSING. The storage key `nym_dev_nsec` exists (`storage_keys.dart:141`) but there is no
  modal, no `verifyDevNsec`, and no reserved-name check anywhere in `lib/` (grep: only relay/CSS
  "reserved" hits).
- Gap: Reserved-nickname gating is absent — either the reserved name is silently allowed, or the
  feature simply doesn't exist on native. User-visible divergence from PWA for that one path.
- Fix approach: Add a small dialog mirroring `devNsecModal` (title, message, nsec password field,
  inline error, Cancel/Verify). Trigger it from the nick/setup name-submit path when the entered
  name matches the reserved handle; verify the decoded nsec's pubkey equals the hardcoded developer
  pubkey before accepting. Confirm the reserved handle + dev pubkey constant with the PWA source.
- Effort: M  Risk: low  Confidence: med

---

### F11: Vault settings — missing cross-device "encrypt here too?" prompt  [SEVERITY: low]
- PWA: `js/modules/key-vault.js:415-437` (`maybePromptEncryptAtRest`) — after settings sync, if the
  user enabled identity encryption on another device (`nym_encrypt_at_rest_pref === '1'`), this
  device isn't encrypted, a secret is persisted, and the prompt wasn't dismissed, it shows a
  "Protect your identity here too?" modal (body copy at :428-430; buttons "Not now" /(dismiss)/
  "Set up"→`openVaultSettings`).
- Flutter: The storage keys exist (`identity_vault.dart:139-140` writes `encryptAtRestPref` /
  clears `encryptAtRestPromptDismissed`; `storage_keys.dart:28-30`) and `storage_sync.dart:130`
  sync's the hint, but there is NO UI that surfaces the prompt (grep "Protect your identity":
  none).
- Gap: A user who turned on encryption elsewhere is never invited to set it up on this device — the
  cross-device nudge is silently dropped.
- Fix approach: After settings sync completes, call a `maybePromptEncryptAtRest()` equivalent that
  checks the same conditions and shows a confirm dialog (ideally via the new F6 component) with
  "Not now"/"Set up", routing "Set up" to `VaultSettingsModal.open`. Persist the dismissed flag.
- Effort: S  Risk: low  Confidence: high

---

### F12: Vault disable — no dedicated re-auth prompt / fresh biometric challenge  [SEVERITY: low]
- PWA: `js/modules/key-vault.js:475-498` (`_vaultReauth`) — turning encryption off triggers a fresh
  factor check: for password/PIN a separate "Confirm it's you" modal ("Enter your password or PIN
  to turn off identity encryption", Cancel/Confirm); for passkey/biometric a fresh `testVaultUnlock`
  authenticator interaction. Only on success does `disableVault` run (key-vault.js:519-529).
- Flutter: `lib/features/identity/vault_settings_modal.dart:298-325` (`_disable`) — for
  password/PIN it reads the inline `_pw` field shown in the enabled view (:110-118) rather than a
  distinct "Confirm it's you" prompt; for biometric it does re-auth via `_biometricAuth` (good).
  Functional but the password path is an inline field, not the PWA's modal, and the disable error
  copy is hardcoded.
- Gap: Minor UX divergence — the "Confirm it's you" step is folded into the main panel for
  password/PIN. Acceptable, but not 1:1 with the PWA's explicit reauth modal.
- Fix approach: Optional. If matching the PWA exactly, present a separate confirm-password dialog
  (reuse F6's prompt) on "Turn off" instead of the inline field. Low priority.
- Effort: S  Risk: low  Confidence: med

---

### F13: Setup & new-PM inputs hide character counters present in the PWA  [SEVERITY: low]
- PWA: char counters shown live — setup nickname `nymInputCharCount 0/20` (`index.html:1281`), setup
  bio `setupBioCharCount 0/150` (:1330); new-PM group name `pmGroupNameCharCount 0/40` (:317), group
  description `0/150`. The generic `.input-char-count` styles warn/limit colors.
- Flutter: Setup fields use `counterText: ''` (`setup_modal.dart:277`) → no counters; new-PM group
  name uses `counterText:''` (`new_pm_modal.dart:213`). (Nick-edit DOES show `n/20` and `n/150`
  counters — setup/new-PM are inconsistent with it.)
- Gap: No visible "n/max" feedback on setup nickname/bio and new-PM group name; the field silently
  stops accepting input at the limit. Minor but a noticeable inconsistency (nick-edit has them).
- Fix approach: Drop the `counterText:''` overrides (or render a right-aligned `${len}/${max}`
  Text like nick-edit does at :229-235, :350-354) for the setup nickname/bio and new-PM group-name
  fields.
- Effort: S  Risk: low  Confidence: high

---

### F14: nsec reveal row missing a Copy button (visibility-toggle only)  [SEVERITY: low]
- PWA: `index.html:1242-1243` — the revealed nsec field has TWO icon buttons: visibility toggle
  (`toggleNsecVisibility`) AND copy (`copyRevealedNsec`).
- Flutter: `lib/features/identity/nick_edit_modal.dart:494-499` — only the visibility toggle icon;
  no copy button.
- Gap: User can view but not one-tap-copy their nsec from the reveal panel; they'd have to select
  text manually (and it's in a non-selectable `Text`). Friction when backing up the key.
- Fix approach: Add a Copy `IconButton` next to the visibility toggle in `_nsecRow` that copies the
  decoded nsec via `Clipboard.setData` and shows a brief confirmation.
- Effort: S  Risk: low  Confidence: high

---

## Faithful ports (verified, no material gap — listed so the fix phase can skip them)
- **Command palette** — `lib/features/commands/command_palette.dart` vs `commands.js:364-392` +
  `styles-components.css:849-944`. Category grouping, command-name/desc, selected highlight
  (white .08), arrow-nav wrap-around, 200px max-height, `--radius-md` top corners, rgba(20,20,35,.9)
  bg — all match. (Bot-command palette `showBotCommandPalette` not ported here, but that's a
  nymbot concern, out of this slice.)
- **Reactors modal** — `lib/features/reactions/reactors_modal.dart` vs `reactions.js:590-665`.
  Header (40px emoji + count), avatar+nym+`#suffix`+"you" rows, 50-row cap + "+N more", badge
  anchoring (prefer-above/fall-below, viewport clamp), row→context-menu — all faithful.
- **Translate language prompt** — `lib/features/translate/translate_language_prompt.dart` vs
  `translate.js:124-192`. Title/desc, search filter, sorted language grid, tap→pop(code), backdrop
  cancel. Language list parity (≈133 entries each).
- **Poll-create modal** — `lib/features/polls/poll_create_modal.dart` vs `index.html:839-863` +
  `app.js:2489-2523`. Question (280) + 2 starting options, add up to 6 then hide the add button,
  first-two rows non-removable, ≤100/option — exact match. (PWA shows `showAppAlert` on invalid;
  Flutter disables the button instead — acceptable/arguably better.)
- **Nostr login modal** — `lib/features/identity/nostr_login_modal.dart` vs `index.html:1017-1087`.
  Disabled NIP-07 button, NIP-46 remote-signer (nostrconnect QR + bunker paste + status), paste-
  nsec with validation + error line. (Minor: PWA has a "Copy" button for the connection string;
  Flutter shows the QR but no copy button — low.)
- **Vault boot-unlock** — `lib/features/identity/vault_boot_unlock.dart` vs
  `key-vault.js:327-400`. Method-adaptive (password/PIN field vs biometric button), Unlock + Forget
  identity, inline error → retry, forget-confirm. Faithful (error shown inline rather than a
  separate `_vaultErrorModal`, which is fine).
- **Panic overlay** — `lib/features/identity/panic_overlay.dart` vs `panic.js:84-199`. "Encrypting"
  title, 40×8 scramble grid (~60ms), staged status lines ("Encrypting local store…", "Shredding
  local databases…", "Keys destroyed."), sliding indeterminate fill, opaque bg, ~1.5s min hold.
- **Vault settings modal** — `lib/features/identity/vault_settings_modal.dart` vs
  `key-vault.js:504-602`. Enabled vs setup states, method dropdown, password+confirm, PIN
  digit-strip, Enable/Turn-off, busy/error states. (Intentional platform adaptation: PWA offers a
  WebAuthn "Passkey" option (4 methods); native offers Password/PIN/Biometric (3) — documented
  TODO at :260-263, acceptable since native has no WebAuthn-PRF. See F12 for the disable-reauth
  nuance.)

---

## Incidental (non-UI, noted in passing)
- **No global toast/snackbar system in the PWA to port.** The PWA has NO `.toast`/`.snackbar`
  class and no `showToast`; transient feedback is done via `displaySystemMessage` (an in-chat
  system line) and the `.app-dialog` alert/confirm (F6). Flutter's scattered `ScaffoldMessenger`
  SnackBars are therefore a *reasonable* substitute, but they are styled per-site and don't match
  any PWA component. If a consistent transient-feedback surface is desired, standardize one
  alongside F6 rather than chasing a non-existent PWA toast. (Flagged because the brief lists
  "toast" as an item — there is no PWA toast to mirror.)
