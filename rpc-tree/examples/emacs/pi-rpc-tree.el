;;; pi-rpc-tree.el --- Emacs tree UI for Pi RPC sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; Native Emacs client for the rpc-tree Pi extension.
;; It renders the current session JSONL as a navigable tree buffer, then asks the
;; installed `/rpc-tree` extension command to perform the actual Pi-owned tree
;; navigation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'pp)
(require 'subr-x)

(declare-function pi-coding-agent--get-chat-buffer "pi-coding-agent-ui")
(declare-function pi-coding-agent--get-input-buffer "pi-coding-agent-ui")
(declare-function pi-coding-agent--get-process "pi-coding-agent-core")
(declare-function pi-coding-agent--rpc-async "pi-coding-agent-core")
(declare-function pi-coding-agent--rpc-sync "pi-coding-agent-core")
(declare-function pi-coding-agent--display-buffers "pi-coding-agent-ui")
(declare-function pi-coding-agent--load-session-history "pi-coding-agent-menu")
(declare-function pi-coding-agent--refresh-session-state "pi-coding-agent-menu")
(declare-function pi-coding-agent--session-transition-ready-p "pi-coding-agent-menu")

(defgroup pi-rpc-tree nil
  "Native Emacs tree UI for Pi RPC sessions."
  :group 'tools)

(defface pi-rpc-tree-current-face
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face for the active leaf entry in `pi-rpc-tree-mode'.")

(defface pi-rpc-tree-active-path-face
  '((t (:inherit font-lock-constant-face)))
  "Face for entries on the active branch path.")

(defface pi-rpc-tree-user-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for user entries in `pi-rpc-tree-mode'.")

(defface pi-rpc-tree-assistant-face
  '((t (:inherit default)))
  "Face for assistant entries in `pi-rpc-tree-mode'.")

(defface pi-rpc-tree-tool-face
  '((t (:inherit font-lock-comment-face)))
  "Face for tool/evidence entries in `pi-rpc-tree-mode'.")

(defface pi-rpc-tree-meta-face
  '((t (:inherit font-lock-comment-face)))
  "Face for metadata in `pi-rpc-tree-mode'.")

(defface pi-rpc-tree-label-face
  '((t (:inherit font-lock-string-face :weight bold)))
  "Face for entry labels in `pi-rpc-tree-mode'.")

(defcustom pi-rpc-tree-max-prefix-width 48
  "Maximum visual width of connector indentation in `pi-rpc-tree-mode'.
Deep branching sessions can otherwise push entries far off screen."
  :type 'integer
  :group 'pi-rpc-tree)

(defcustom pi-rpc-tree-compact-linear-chains t
  "Render single-child chains without increasing indentation.
Pi sessions are often mostly linear.  Without compaction, the start of a
session becomes a long diagonal staircase before any real branch appears."
  :type 'boolean
  :group 'pi-rpc-tree)

(defcustom pi-rpc-tree-show-evidence t
  "When non-nil, render tool calls/results and metadata as evidence rows.
Evidence rows are visible for audit/debugging, but they are inspect-only: RET
will not navigate Pi's branch leaf to an individual tool call/result."
  :type 'boolean
  :group 'pi-rpc-tree)

;; This is personal config, not a reusable package: prefer full trace by default
;; even when this file is hot-reloaded after the old defcustom default was nil.
(setq pi-rpc-tree-show-evidence t)

(defcustom pi-rpc-tree-collapse-evidence-groups t
  "When non-nil, show evidence as collapsed trace drawers by default."
  :type 'boolean
  :group 'pi-rpc-tree)

(defcustom pi-rpc-tree-flat-conversation-spine t
  "When non-nil, render user/assistant turns as a flat vertical spine.
Trace drawers remain nested under the turn they belong to, but ordinary linear
conversation flow does not staircase to the right."
  :type 'boolean
  :group 'pi-rpc-tree)

(defconst pi-rpc-tree-rpc-command-name "rpc-tree"
  "Pi extension command used for RPC tree navigation.")

(defconst pi-rpc-tree-rpc-event-prefix "rpc-tree:event "
  "Machine-readable notification prefix emitted by the rpc-tree extension.")

(defconst pi-rpc-tree--missing-leaf-sentinel :pi-rpc-tree-missing-leaf
  "Internal sentinel for no remembered leaf entry.")

(defconst pi-rpc-tree--nil-leaf-sentinel :pi-rpc-tree-nil-leaf
  "Internal sentinel for a remembered nil/root leaf.")

(defvar pi-rpc-tree--leaf-by-session (make-hash-table :test 'equal)
  "Best-known live leaf id by session file.
Session files do not persist leaf-only branch moves until a new entry is
appended, so the Emacs UI remembers navigation performed in this Emacs session.")

(defvar-local pi-rpc-tree--chat-buffer nil)
(defvar-local pi-rpc-tree--input-buffer nil)
(defvar-local pi-rpc-tree--process nil)
(defvar-local pi-rpc-tree--session-file nil)
(defvar-local pi-rpc-tree--entries nil)
(defvar-local pi-rpc-tree--nodes nil)
(defvar-local pi-rpc-tree--node-by-id nil)
(defvar-local pi-rpc-tree--parent-by-id nil)
(defvar-local pi-rpc-tree--collapsed nil)
(defvar-local pi-rpc-tree--current-leaf-id nil)
(defvar-local pi-rpc-tree--display-leaf-id nil)
(defvar-local pi-rpc-tree--show-evidence nil)
(defvar-local pi-rpc-tree--expanded-evidence-groups nil)

(defun pi-rpc-tree--remember-leaf (session-file leaf-id)
  "Remember LEAF-ID for SESSION-FILE, preserving nil as the root leaf."
  (when session-file
    (puthash session-file
             (or leaf-id pi-rpc-tree--nil-leaf-sentinel)
             pi-rpc-tree--leaf-by-session)))

(defun pi-rpc-tree--remembered-leaf-or (session-file fallback)
  "Return remembered leaf for SESSION-FILE, or FALLBACK when none is known.
A remembered nil/root leaf is distinct from no remembered value."
  (let ((value (if session-file
                   (gethash session-file
                            pi-rpc-tree--leaf-by-session
                            pi-rpc-tree--missing-leaf-sentinel)
                 pi-rpc-tree--missing-leaf-sentinel)))
    (cond
     ((eq value pi-rpc-tree--missing-leaf-sentinel) fallback)
     ((eq value pi-rpc-tree--nil-leaf-sentinel) nil)
     (t value))))

(defun pi-rpc-tree--entry-type (entry)
  "Return ENTRY type string."
  (plist-get entry :type))

(defun pi-rpc-tree--entry-id (entry)
  "Return ENTRY id string."
  (plist-get entry :id))

(defun pi-rpc-tree--entry-parent-id (entry)
  "Return ENTRY parent id string or nil."
  (plist-get entry :parentId))

(defun pi-rpc-tree--message (entry)
  "Return message plist for ENTRY."
  (plist-get entry :message))

(defun pi-rpc-tree--content-text (content)
  "Extract text from CONTENT, which may be string or content block list."
  (cond
   ((stringp content) content)
   ((listp content)
    (mapconcat
     (lambda (block)
       (if (equal (plist-get block :type) "text")
           (or (plist-get block :text) "")
         ""))
     content ""))
   (t "")))

(defun pi-rpc-tree--one-line (text &optional width)
  "Return TEXT as one trimmed line at WIDTH characters."
  (let* ((width (or width 96))
         (line (string-trim (replace-regexp-in-string "[[:space:]\n]+" " " (or text "")))))
    (if (<= (length line) width)
        line
      (concat (substring line 0 (max 0 (1- width))) "…"))))

(defun pi-rpc-tree--content-has-text-p (content)
  "Return non-nil when CONTENT contains non-whitespace user-visible text."
  (not (string-empty-p (string-trim (pi-rpc-tree--content-text content)))))

(defun pi-rpc-tree--content-tool-calls (content)
  "Return tool call names present in CONTENT blocks."
  (when (listp content)
    (cl-loop for block in content
             when (equal (plist-get block :type) "toolCall")
             collect (or (plist-get block :name)
                         (plist-get block :toolName)
                         "tool"))))

(defun pi-rpc-tree--evidence-group-entry-p (entry)
  "Return non-nil when ENTRY is a synthetic evidence drawer."
  (equal (pi-rpc-tree--entry-type entry) "evidence_group"))

(defun pi-rpc-tree--evidence-entry-names (entry)
  "Return short category names for evidence ENTRY."
  (pcase (pi-rpc-tree--entry-type entry)
    ("message"
     (let* ((msg (pi-rpc-tree--message entry))
            (role (plist-get msg :role)))
       (pcase role
         ("assistant" (or (pi-rpc-tree--content-tool-calls (plist-get msg :content))
                          '("assistant")))
         ("toolResult" (list (or (plist-get msg :toolName) "result")))
         ("bashExecution" '("bash"))
         (_ (list (or role "message"))))))
    ("model_change" '("model"))
    ("thinking_level_change" '("think"))
    ("session_info" '("session"))
    ("label" '("label"))
    (other (list (or other "entry")))))

(defun pi-rpc-tree--format-evidence-counts (names)
  "Return compact count summary for evidence NAMES."
  (let ((counts (make-hash-table :test 'equal))
        ordered)
    (dolist (name names)
      (unless (gethash name counts)
        (push name ordered))
      (puthash name (1+ (or (gethash name counts) 0)) counts))
    (mapconcat (lambda (name)
                 (let ((count (gethash name counts)))
                   (if (> count 1)
                       (format "%s×%d" name count)
                     name)))
               (nreverse ordered)
               " ")))

(defun pi-rpc-tree--conversation-entry-p (entry)
  "Return non-nil when ENTRY is a conversational branch target.
Tool calls/results, model changes, thinking-level changes and other trace
metadata are evidence, not places where RET should move the Pi branch leaf."
  (pcase (pi-rpc-tree--entry-type entry)
    ("message"
     (let* ((msg (pi-rpc-tree--message entry))
            (role (plist-get msg :role)))
       (pcase role
         ("user" t)
         ("assistant" (pi-rpc-tree--content-has-text-p (plist-get msg :content)))
         (_ nil))))
    ("custom_message" t)
    ("branch_summary" t)
    ("custom" (member (plist-get entry :customType) '("workspace-park")))
    (_ nil)))

(defun pi-rpc-tree--entry-navigable-p (entry)
  "Return non-nil when ENTRY may be used for Pi tree navigation."
  (pi-rpc-tree--conversation-entry-p entry))

(defun pi-rpc-tree--visible-entry-p (entry)
  "Return non-nil when ENTRY should be rendered in the current tree view."
  (or pi-rpc-tree--show-evidence
      (pi-rpc-tree--conversation-entry-p entry)))

(defun pi-rpc-tree--entry-role (entry)
  "Return display role for ENTRY."
  (pcase (pi-rpc-tree--entry-type entry)
    ("message"
     (let* ((msg (pi-rpc-tree--message entry))
            (role (or (plist-get msg :role) "message"))
            (content (plist-get msg :content)))
       (cond
        ((and (equal role "assistant")
              (not (pi-rpc-tree--content-has-text-p content))
              (pi-rpc-tree--content-tool-calls content))
         "toolCall")
        ((equal role "toolResult") "result")
        ((equal role "bashExecution") "bash")
        (t role))))
    ("evidence_group" "trace")
    ("custom_message" "custom")
    ("branch_summary" "branch")
    ("compaction" "compact")
    ("model_change" "model")
    ("thinking_level_change" "think")
    ("session_info" "session")
    ("label" "label")
    (other (or other "entry"))))

(defun pi-rpc-tree--entry-preview (entry)
  "Return preview text for ENTRY."
  (pcase (pi-rpc-tree--entry-type entry)
    ("message"
     (let* ((msg (pi-rpc-tree--message entry))
            (role (plist-get msg :role)))
       (pcase role
         ("user" (pi-rpc-tree--one-line (pi-rpc-tree--content-text (plist-get msg :content))))
         ("assistant"
          (let* ((content (plist-get msg :content))
                 (text (pi-rpc-tree--content-text content))
                 (calls (pi-rpc-tree--content-tool-calls content)))
            (cond
             ((not (string-empty-p (string-trim text)))
              (pi-rpc-tree--one-line text))
             (calls
              (pi-rpc-tree--one-line (format "calls %s" (mapconcat #'identity calls ", "))))
             (t ""))))
         ("toolResult" (pi-rpc-tree--one-line
                         (format "%s: %s"
                                 (or (plist-get msg :toolName) "tool")
                                 (pi-rpc-tree--content-text (plist-get msg :content)))))
         ("bashExecution" (pi-rpc-tree--one-line (format "$ %s" (or (plist-get msg :command) ""))))
         (_ (pi-rpc-tree--one-line (pi-rpc-tree--content-text (plist-get msg :content)))))))
    ("evidence_group"
     (let ((count (or (plist-get entry :count) 0))
           (summary (or (plist-get entry :summary) "")))
       (format "%d trace entries%s%s"
               count
               (if (string-empty-p summary) "" ": ")
               summary)))
    ("custom_message" (pi-rpc-tree--one-line (pi-rpc-tree--content-text (plist-get entry :content))))
    ("branch_summary" (pi-rpc-tree--one-line (plist-get entry :summary)))
    ("compaction" (pi-rpc-tree--one-line (plist-get entry :summary)))
    ("model_change" (format "%s/%s" (plist-get entry :provider) (plist-get entry :modelId)))
    ("thinking_level_change" (or (plist-get entry :thinkingLevel) ""))
    ("session_info" (or (plist-get entry :name) "(unnamed)"))
    ("label" (format "%s: %s"
                      (or (plist-get entry :targetId) "?")
                      (or (plist-get entry :label) "(clear)")))
    (_ "")))

(defun pi-rpc-tree--entry-face (entry current-p active-path-p)
  "Return face for ENTRY considering CURRENT-P and ACTIVE-PATH-P."
  (cond
   ((not (pi-rpc-tree--conversation-entry-p entry)) 'pi-rpc-tree-tool-face)
   (current-p 'pi-rpc-tree-current-face)
   (active-path-p 'pi-rpc-tree-active-path-face)
   ((equal (pi-rpc-tree--entry-type entry) "message")
    (pcase (plist-get (pi-rpc-tree--message entry) :role)
      ("user" 'pi-rpc-tree-user-face)
      ("assistant" 'pi-rpc-tree-assistant-face)
      (_ 'default)))
   ((member (pi-rpc-tree--entry-type entry) '("session_info" "label"))
    'pi-rpc-tree-meta-face)
   (t 'default)))

(defun pi-rpc-tree--read-jsonl (file)
  "Read session JSONL FILE and return plists excluding the session header."
  (let (entries)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (string-trim (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position)))))
          (unless (string-empty-p line)
            (let ((entry (json-parse-string line
                                            :object-type 'plist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object :json-false)))
              (unless (equal (plist-get entry :type) "session")
                (push entry entries)))))
        (forward-line 1)))
    (nreverse entries)))

(defun pi-rpc-tree--build-model (entries)
  "Build tree model from ENTRIES.
Returns (NODES NODE-BY-ID PARENT-BY-ID)."
  (let ((node-by-id (make-hash-table :test 'equal))
        (children-by-parent (make-hash-table :test 'equal))
        (parent-by-id (make-hash-table :test 'equal))
        (labels (make-hash-table :test 'equal))
        roots)
    (dolist (entry entries)
      (when (equal (pi-rpc-tree--entry-type entry) "label")
        (let ((target (plist-get entry :targetId))
              (label (plist-get entry :label)))
          (when target
            (if (and label (not (eq label :json-false)))
                (puthash target label labels)
              (remhash target labels))))))
    (dolist (entry entries)
      (let* ((id (pi-rpc-tree--entry-id entry))
             (parent (pi-rpc-tree--entry-parent-id entry))
             (node (list :entry entry :children nil)))
        (when id
          (puthash id node node-by-id)
          (puthash id parent parent-by-id)
          (when-let* ((label (gethash id labels)))
            (setq node (plist-put node :label label))
            (puthash id node node-by-id))
          (push node (gethash parent children-by-parent)))))
    ;; Attach children preserving file order.
    (maphash (lambda (_parent children)
               (dolist (node children)
                 (let* ((entry (plist-get node :entry))
                        (id (pi-rpc-tree--entry-id entry))
                        (ordered-children (nreverse (gethash id children-by-parent))))
                   (plist-put node :children ordered-children))))
             children-by-parent)
    (setq roots (nreverse (gethash nil children-by-parent)))
    (list roots node-by-id parent-by-id)))

(defun pi-rpc-tree--nearest-visible-ancestor-id (id node-by-id parent-by-id)
  "Return nearest visible ancestor id for ID using NODE-BY-ID and PARENT-BY-ID."
  (let ((parent (gethash id parent-by-id))
        found)
    (while (and parent (not found))
      (let ((node (gethash parent node-by-id)))
        (if (and node (pi-rpc-tree--visible-entry-p (plist-get node :entry)))
            (setq found parent)
          (setq parent (gethash parent parent-by-id)))))
    found))

(defun pi-rpc-tree--nearest-conversation-ancestor-id (id node-by-id parent-by-id)
  "Return nearest conversational ancestor id for ID.
This keeps evidence rows visually attached to the user/assistant turn they
belong to instead of rendering every tool call/result as another selectable
step in a long linear trace."
  (let ((parent (gethash id parent-by-id))
        found)
    (while (and parent (not found))
      (let ((node (gethash parent node-by-id)))
        (if (and node (pi-rpc-tree--conversation-entry-p (plist-get node :entry)))
            (setq found parent)
          (setq parent (gethash parent parent-by-id)))))
    found))

(defun pi-rpc-tree--display-leaf-id-for (leaf-id node-by-id parent-by-id)
  "Return visible leaf marker id for LEAF-ID in the current evidence mode."
  (cond
   ((not leaf-id) nil)
   ((or pi-rpc-tree--show-evidence
        (when-let* ((node (gethash leaf-id node-by-id)))
          (pi-rpc-tree--visible-entry-p (plist-get node :entry))))
    leaf-id)
   (t (pi-rpc-tree--nearest-visible-ancestor-id leaf-id node-by-id parent-by-id))))

(defun pi-rpc-tree--build-display-nodes (entries node-by-id parent-by-id)
  "Build visible display nodes from ENTRIES.
Evidence rows are grouped into synthetic trace drawers under the nearest
conversation entry.  When `pi-rpc-tree-flat-conversation-spine' is non-nil,
conversation rows are rendered as a straight vertical list rather than a linear
parent/child staircase."
  (let ((children-by-parent (make-hash-table :test 'equal))
        (evidence-children-by-parent (make-hash-table :test 'equal))
        (evidence-names-by-parent (make-hash-table :test 'equal))
        (evidence-group-by-parent (make-hash-table :test 'equal))
        roots)
    (cl-labels ((evidence-key (parent) (or parent "__root__"))
                (ensure-evidence-group
                 (parent)
                 (let ((key (evidence-key parent)))
                   (or (gethash key evidence-group-by-parent)
                       (let* ((id (format "evidence:%s" key))
                              (entry (list :type "evidence_group"
                                           :id id
                                           :parentId parent
                                           :count 0
                                           :summary ""))
                              (node (list :entry entry :children nil)))
                         (puthash key node evidence-group-by-parent)
                         (push node (gethash parent children-by-parent))
                         node)))))
      (dolist (entry entries)
        (let ((id (pi-rpc-tree--entry-id entry)))
          (when (and id (pi-rpc-tree--visible-entry-p entry))
            (let* ((raw-node (gethash id node-by-id))
                   (node (copy-sequence raw-node))
                   (conversation-p (pi-rpc-tree--conversation-entry-p entry))
                   (parent (if (and conversation-p pi-rpc-tree-flat-conversation-spine)
                               nil
                             (pi-rpc-tree--nearest-conversation-ancestor-id id node-by-id parent-by-id))))
              (setq node (plist-put node :children nil))
              (if conversation-p
                  (push node (gethash parent children-by-parent))
                (let* ((group (ensure-evidence-group parent))
                       (key (evidence-key parent))
                       (group-entry (plist-get group :entry))
                       (names (pi-rpc-tree--evidence-entry-names entry))
                       (all-names (append names (gethash key evidence-names-by-parent))))
                  (puthash key all-names evidence-names-by-parent)
                  (push node (gethash key evidence-children-by-parent))
                  (setq group-entry
                        (plist-put group-entry :count
                                   (1+ (or (plist-get group-entry :count) 0))))
                  (setq group-entry
                        (plist-put group-entry :summary
                                   (pi-rpc-tree--format-evidence-counts (reverse all-names))))
                  (setq group (plist-put group :entry group-entry))
                  (puthash key group evidence-group-by-parent))))))))
    (maphash (lambda (key group)
               (plist-put group :children
                          (nreverse (gethash key evidence-children-by-parent))))
             evidence-group-by-parent)
    (maphash (lambda (_parent children)
               (dolist (node children)
                 (let* ((entry (plist-get node :entry))
                        (id (pi-rpc-tree--entry-id entry))
                        (ordered-children (nreverse (gethash id children-by-parent))))
                   (when ordered-children
                     (plist-put node :children ordered-children)))))
             children-by-parent)
    (setq roots (nreverse (gethash nil children-by-parent)))
    roots))

(defun pi-rpc-tree--index-display-nodes (nodes &optional table)
  "Return hash TABLE containing display NODES by id, including synthetic nodes."
  (let ((table (or table (make-hash-table :test 'equal)))
        (stack nodes))
    (while stack
      (let* ((node (pop stack))
             (entry (plist-get node :entry))
             (id (pi-rpc-tree--entry-id entry)))
        (when id
          (puthash id node table))
        (setq stack (append (plist-get node :children) stack))))
    table))

(defun pi-rpc-tree--last-entry-id (entries)
  "Return id of last entry in ENTRIES."
  (when-let* ((entry (car (last entries))))
    (pi-rpc-tree--entry-id entry)))

(defun pi-rpc-tree--active-path-ids (leaf-id parent-by-id)
  "Return hash table of ids on path to LEAF-ID using PARENT-BY-ID."
  (let ((ids (make-hash-table :test 'equal))
        (id leaf-id))
    (while id
      (puthash id t ids)
      (setq id (gethash id parent-by-id)))
    ids))

(defun pi-rpc-tree--line-entry-id ()
  "Return tree entry id at point.
If point is on the trailing blank line, use the previous tree entry."
  (or (get-text-property (line-beginning-position) 'pi-rpc-tree-entry-id)
      (when (and (string-empty-p (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position)))
                 (> (line-beginning-position) (point-min)))
        (save-excursion
          (forward-line -1)
          (get-text-property (line-beginning-position) 'pi-rpc-tree-entry-id)))))

(defun pi-rpc-tree--line-node ()
  "Return tree node at point."
  (when-let* ((id (pi-rpc-tree--line-entry-id)))
    (gethash id pi-rpc-tree--node-by-id)))

(defun pi-rpc-tree--collapsed-p (id)
  "Return non-nil when ID is collapsed."
  (and id pi-rpc-tree--collapsed (gethash id pi-rpc-tree--collapsed)))

(defun pi-rpc-tree--node-collapsed-p (id entry)
  "Return non-nil when display node ID/ENTRY is collapsed."
  (cond
   ((pi-rpc-tree--evidence-group-entry-p entry)
    (and pi-rpc-tree-collapse-evidence-groups
         (not (and pi-rpc-tree--expanded-evidence-groups
                   (gethash id pi-rpc-tree--expanded-evidence-groups)))))
   (t (pi-rpc-tree--collapsed-p id))))

(defun pi-rpc-tree--shorten-prefix (prefix)
  "Return PREFIX capped to `pi-rpc-tree-max-prefix-width'."
  (if (<= (string-width prefix) pi-rpc-tree-max-prefix-width)
      prefix
    (concat "…" (substring prefix (- (length prefix) (1- pi-rpc-tree-max-prefix-width))))))

(defun pi-rpc-tree--insert-node-line (node prefix is-last depth sibling-count active-path)
  "Insert one NODE line with PREFIX, IS-LAST, DEPTH and ACTIVE-PATH.
SIBLING-COUNT is used to keep mostly-linear chains visually flat.
Return (CHILDREN NEXT-PREFIX NEXT-DEPTH COLLAPSED)."
  (let* ((prefix (pi-rpc-tree--shorten-prefix prefix))
         (entry (plist-get node :entry))
         (id (pi-rpc-tree--entry-id entry))
         (children (plist-get node :children))
         (has-children (and children t))
         (collapsed (pi-rpc-tree--node-collapsed-p id entry))
         (conversation-p (pi-rpc-tree--conversation-entry-p entry))
         (evidence-group-p (pi-rpc-tree--evidence-group-entry-p entry))
         (navigable-p (pi-rpc-tree--entry-navigable-p entry))
         (line-has-connector (if pi-rpc-tree-compact-linear-chains
                                 (> sibling-count 1)
                               (> depth 0)))
         (connector (if line-has-connector (if is-last "└─ " "├─ ") ""))
         (next-prefix (if pi-rpc-tree-compact-linear-chains
                          (if line-has-connector
                              (concat prefix (if is-last "   " "│  "))
                            prefix)
                        (if (= depth 0) "" (concat prefix (if is-last "   " "│  ")))))
         (next-depth (if pi-rpc-tree-compact-linear-chains
                         (if line-has-connector (1+ depth) depth)
                       (1+ depth)))
         (marker (cond
                  ((equal id pi-rpc-tree--display-leaf-id) "●")
                  (evidence-group-p (if collapsed "▸" "▾"))
                  ((not conversation-p) "↳")
                  ((gethash id active-path) "◆")
                  (has-children (if collapsed "▸" "▾"))
                  (t " ")))
         (display-id (if evidence-group-p "trace" id))
         (role (truncate-string-to-width
                (if evidence-group-p "" (pi-rpc-tree--entry-role entry)) 9 0 ?\s))
         (label (plist-get node :label))
         (line-start (point))
         (face (pi-rpc-tree--entry-face entry
                                       (equal id pi-rpc-tree--display-leaf-id)
                                       (gethash id active-path))))
    (insert prefix connector)
    (insert (propertize marker 'face face) " ")
    (insert (propertize display-id 'face 'pi-rpc-tree-meta-face) " ")
    (insert (propertize role 'face face))
    (when label
      (insert " " (propertize (format "[%s]" label) 'face 'pi-rpc-tree-label-face)))
    (insert " " (propertize (pi-rpc-tree--entry-preview entry) 'face face))
    (add-text-properties line-start (point)
                         (list 'pi-rpc-tree-entry-id id
                               'pi-rpc-tree-entry-kind (if conversation-p 'conversation 'evidence)
                               'pi-rpc-tree-navigable navigable-p))
    (insert "\n")
    (list children next-prefix next-depth collapsed)))

(defun pi-rpc-tree--insert-nodes (nodes active-path)
  "Insert NODES iteratively using ACTIVE-PATH.
Avoids deep recursive rendering for long mostly-linear sessions."
  (let (stack)
    (let ((count (length nodes))
          (index (length nodes)))
      (dolist (node (reverse nodes))
        (push (list node "" (= index count) 0 count) stack)
        (setq index (1- index))))
    (while stack
      (pcase-let ((`(,node ,prefix ,is-last ,depth ,sibling-count) (pop stack)))
        (pcase-let ((`(,children ,next-prefix ,next-depth ,collapsed)
                     (pi-rpc-tree--insert-node-line node prefix is-last depth sibling-count active-path)))
          (unless collapsed
            (let ((count (length children))
                  (index (length children)))
              (dolist (child (reverse children))
                (push (list child next-prefix (= index count) next-depth count) stack)
                (setq index (1- index))))))))))

(defun pi-rpc-tree-refresh ()
  "Refresh the current Pi tree buffer."
  (interactive)
  (unless (and pi-rpc-tree--session-file (file-exists-p pi-rpc-tree--session-file))
    (user-error "No readable Pi session file"))
  (let* ((inhibit-read-only t)
         (entries (pi-rpc-tree--read-jsonl pi-rpc-tree--session-file))
         (model (pi-rpc-tree--build-model entries))
         (node-by-id (nth 1 model))
         (parent-by-id (nth 2 model))
         (display-nodes (pi-rpc-tree--build-display-nodes entries node-by-id parent-by-id))
         (leaf (pi-rpc-tree--remembered-leaf-or
                pi-rpc-tree--session-file
                (or pi-rpc-tree--current-leaf-id
                    (pi-rpc-tree--last-entry-id entries))))
         (display-leaf (or (pi-rpc-tree--display-leaf-id-for leaf node-by-id parent-by-id)
                           leaf)))
    (setq pi-rpc-tree--entries entries
          pi-rpc-tree--node-by-id (pi-rpc-tree--index-display-nodes display-nodes node-by-id)
          pi-rpc-tree--parent-by-id parent-by-id
          pi-rpc-tree--nodes display-nodes
          pi-rpc-tree--current-leaf-id leaf
          pi-rpc-tree--display-leaf-id display-leaf)
    (erase-buffer)
    (insert (propertize "Pi Session Tree" 'face 'bold) "\n")
    (insert (propertize (abbreviate-file-name pi-rpc-tree--session-file)
                        'face 'pi-rpc-tree-meta-face)
            "\n\n")
    (insert (propertize
             (format "RET navigate conv  o inspect  M-RET summarize  TAB fold  v %s evidence  r refresh  q restore chat"
                     (if pi-rpc-tree--show-evidence "hide" "show"))
             'face 'pi-rpc-tree-meta-face)
            "\n\n")
    (let ((active-path (pi-rpc-tree--active-path-ids display-leaf pi-rpc-tree--parent-by-id)))
      (pi-rpc-tree--insert-nodes pi-rpc-tree--nodes active-path))
    (goto-char (point-min))
    (forward-line 4)
    (when (eobp) (forward-line -1))))

(defun pi-rpc-tree--editor-text-for-entry (entry)
  "Return editor text that Pi /tree would restore for ENTRY."
  (pcase (pi-rpc-tree--entry-type entry)
    ("message"
     (if (equal (plist-get (pi-rpc-tree--message entry) :role) "user")
         (pi-rpc-tree--content-text (plist-get (pi-rpc-tree--message entry) :content))
       ""))
    ("custom_message" (pi-rpc-tree--content-text (plist-get entry :content)))
    (_ "")))

(defun pi-rpc-tree--set-input-text (input-buf text)
  "Set INPUT-BUF to TEXT when live."
  (when (buffer-live-p input-buf)
    (with-current-buffer input-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text ""))))))

(defun pi-rpc-tree--available-rpc-tree-command (commands)
  "Return `pi-rpc-tree-rpc-command-name' when found in COMMANDS, or nil."
  (when (member pi-rpc-tree-rpc-command-name
                (mapcar (lambda (command) (plist-get command :name)) commands))
    pi-rpc-tree-rpc-command-name))

(defun pi-rpc-tree--tree-command-loaded-p (proc)
  "Return loaded RPC tree command name for PROC, or nil.
This synchronous helper is for diagnostics only; interactive commands use the
async variant so opening/navigating never freezes Emacs."
  (when (and proc (process-live-p proc))
    (let* ((response (ignore-errors (pi-coding-agent--rpc-sync proc '(:type "get_commands") 2)))
           (commands (plist-get (plist-get response :data) :commands)))
      (pi-rpc-tree--available-rpc-tree-command commands))))

(defun pi-rpc-tree--tree-command-loaded-async (proc callback)
  "Call CALLBACK with loaded RPC tree command name, or nil."
  (if (not (and proc (process-live-p proc)))
      (funcall callback nil)
    (pi-coding-agent--rpc-async
     proc
     '(:type "get_commands")
     (lambda (response)
       (funcall callback
                (and (eq (plist-get response :success) t)
                     (pi-rpc-tree--available-rpc-tree-command
                      (plist-get (plist-get response :data) :commands))))))))

(defun pi-rpc-tree--refresh-chat (proc chat-buf &optional callback)
  "Refresh CHAT-BUF from PROC and call CALLBACK after history load."
  (when (and (buffer-live-p chat-buf) proc (process-live-p proc))
    (with-current-buffer chat-buf
      (ignore-errors (pi-coding-agent--refresh-session-state proc chat-buf))
      (pi-coding-agent--load-session-history
       proc
       (lambda (_count)
         (when callback (funcall callback)))
       chat-buf))))

(defun pi-rpc-tree--restore-chat-buffers (chat-buf input-buf &optional tree-buf)
  "Restore CHAT-BUF/INPUT-BUF, replacing TREE-BUF's visible window when possible."
  (when (and (buffer-live-p chat-buf) (buffer-live-p input-buf))
    (let ((tree-win (and (buffer-live-p tree-buf)
                         (get-buffer-window tree-buf nil))))
      (cond
       ((fboundp 'pi-coding-agent--display-buffers)
        (when (window-live-p tree-win)
          (select-window tree-win))
        (pi-coding-agent--display-buffers chat-buf input-buf))
       (t
        (when (window-live-p tree-win)
          (set-window-buffer tree-win chat-buf))
        (when-let* ((input-win (get-buffer-window input-buf nil)))
          (select-window input-win)))))))

(defun pi-rpc-tree-restore-chat ()
  "Restore the Pi chat/input buffers in place of the tree buffer."
  (interactive)
  (pi-rpc-tree--restore-chat-buffers
   pi-rpc-tree--chat-buffer
   pi-rpc-tree--input-buffer
   (current-buffer)))

(defun pi-rpc-tree--pending-rpc-navigation (proc)
  "Return pending rpc-tree navigation plist stored on PROC."
  (and proc (process-get proc 'pi-rpc-tree-pending-rpc-navigation)))

(defun pi-rpc-tree--set-pending-rpc-navigation (proc pending)
  "Store PENDING rpc-tree navigation plist on PROC."
  (when proc
    (process-put proc 'pi-rpc-tree-pending-rpc-navigation pending)))

(defun pi-rpc-tree--clear-pending-rpc-navigation (proc &optional target-id)
  "Clear pending rpc-tree navigation on PROC.
When TARGET-ID is non-nil, clear only if the pending request targets it."
  (when-let* ((pending (pi-rpc-tree--pending-rpc-navigation proc)))
    (when (or (null target-id)
              (equal (plist-get pending :target-id) target-id))
      (process-put proc 'pi-rpc-tree-pending-rpc-navigation nil))))

(defun pi-rpc-tree--refresh-tree-buffer-with-leaf (tree-buf session-file leaf-id leaf-known-p)
  "Refresh TREE-BUF after an event, optionally remembering LEAF-ID."
  (when (buffer-live-p tree-buf)
    (with-current-buffer tree-buf
      (when (and session-file leaf-known-p)
        (pi-rpc-tree--remember-leaf session-file leaf-id)
        (setq pi-rpc-tree--current-leaf-id leaf-id))
      (ignore-errors (pi-rpc-tree-refresh)))))

(defun pi-rpc-tree--send-navigation (command-name id entry summarize tree-buf proc chat-buf input-buf session-file)
  "Ask PROC via COMMAND-NAME to navigate to ID/ENTRY and wait for rpc-tree:event."
  (let ((message (format "/%s --id %s %s" command-name id (if summarize "--summary" "--no-summary"))))
    (message "Pi tree: navigating to %s..." id)
    (pi-rpc-tree--set-pending-rpc-navigation
     proc
     (list :target-id id
           :tree-buf tree-buf
           :chat-buf chat-buf
           :input-buf input-buf
           :session-file session-file
           :editor-text (pi-rpc-tree--editor-text-for-entry entry)
           :summarize summarize
           :started-at (float-time)))
    (pi-coding-agent--rpc-async
     proc
     (list :type "prompt" :message message)
     (lambda (response)
       (if (not (eq (plist-get response :success) t))
           (progn
             (pi-rpc-tree--clear-pending-rpc-navigation proc id)
             (message "Pi tree: navigation command failed%s"
                      (if-let* ((err (plist-get response :error)))
                          (format ": %s" err)
                        "")))
         ;; /rpc-tree prompt success means the extension command was handled, not
         ;; that navigation succeeded.  The authoritative outcome is delivered by
         ;; `rpc-tree:event`; warn only if a current extension failed to emit one.
         (run-at-time
          0.5 nil
          (lambda ()
            (when-let* ((pending (pi-rpc-tree--pending-rpc-navigation proc)))
              (when (equal (plist-get pending :target-id) id)
                (message "Pi tree: /rpc-tree completed without rpc-tree:event; reload Pi if this persists"))))))))))

(defun pi-rpc-tree-inspect-entry ()
  "Inspect the raw JSON/plist entry at point."
  (interactive)
  (let* ((id (pi-rpc-tree--line-entry-id))
         (node (pi-rpc-tree--line-node))
         (entry (plist-get node :entry)))
    (unless (and id entry)
      (user-error "No tree entry on this line"))
    (let ((buf (get-buffer-create (format "*Pi Tree Entry: %s*" id))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Pi tree entry %s\n\n" id))
          (condition-case _err
              (let ((json-start (point)))
                (insert (json-encode entry))
                (when (fboundp 'json-pretty-print)
                  (json-pretty-print json-start (point))))
            (error
             (erase-buffer)
             (insert (format "Pi tree entry %s\n\n%s" id (pp-to-string entry))))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer buf))))

(defun pi-rpc-tree-toggle-evidence ()
  "Toggle visibility of evidence rows such as tool calls/results."
  (interactive)
  (setq pi-rpc-tree--show-evidence (not pi-rpc-tree--show-evidence))
  (pi-rpc-tree-refresh)
  (message "Pi tree: evidence rows %s"
           (if pi-rpc-tree--show-evidence "shown" "hidden")))

(defun pi-rpc-tree--navigate (summarize)
  "Navigate to entry at point.  When SUMMARIZE is non-nil, ask Pi to summarize."
  (let* ((id (pi-rpc-tree--line-entry-id))
         (node (pi-rpc-tree--line-node))
         (entry (plist-get node :entry))
         (chat-buf pi-rpc-tree--chat-buffer)
         (input-buf pi-rpc-tree--input-buffer)
         (tree-buf (current-buffer))
         (proc pi-rpc-tree--process)
         (session-file pi-rpc-tree--session-file))
    (unless (and id entry)
      (user-error "No tree entry on this line"))
    (cond
     ((not (pi-rpc-tree--entry-navigable-p entry))
      (message "Pi tree: evidence rows are not selectable; use o to inspect %s" id))
     ((or (equal id pi-rpc-tree--current-leaf-id)
          (equal id pi-rpc-tree--display-leaf-id))
      (pi-rpc-tree-restore-chat)
      (message "Pi tree: already at %s; restored chat" id))
     (t
      (unless (and proc (process-live-p proc))
        (user-error "Pi process is not live"))
      (message "Pi tree: checking /%s command..." pi-rpc-tree-rpc-command-name)
      (pi-rpc-tree--tree-command-loaded-async
       proc
       (lambda (command-name)
         (if command-name
             (pi-rpc-tree--send-navigation command-name id entry summarize tree-buf proc chat-buf input-buf session-file)
           (message "Pi tree: current Pi process did not load /%s; restart Pi with SPC o q, then SPC o p"
                    pi-rpc-tree-rpc-command-name))))))))

(defun pi-rpc-tree-navigate ()
  "Navigate to the tree entry at point without branch summary."
  (interactive)
  (pi-rpc-tree--navigate nil))

(defun pi-rpc-tree-navigate-with-summary ()
  "Navigate to the tree entry at point with branch summary."
  (interactive)
  (pi-rpc-tree--navigate t))

(defun pi-rpc-tree-toggle-fold ()
  "Toggle fold state for the entry at point."
  (interactive)
  (let* ((id (pi-rpc-tree--line-entry-id))
         (node (and id (gethash id pi-rpc-tree--node-by-id)))
         (entry (plist-get node :entry))
         (children (plist-get node :children)))
    (unless (and id children)
      (user-error "No children to fold here"))
    (if (pi-rpc-tree--evidence-group-entry-p entry)
        (progn
          (unless pi-rpc-tree--expanded-evidence-groups
            (setq pi-rpc-tree--expanded-evidence-groups (make-hash-table :test 'equal)))
          (if (gethash id pi-rpc-tree--expanded-evidence-groups)
              (remhash id pi-rpc-tree--expanded-evidence-groups)
            (puthash id t pi-rpc-tree--expanded-evidence-groups)))
      (if (gethash id pi-rpc-tree--collapsed)
          (remhash id pi-rpc-tree--collapsed)
        (puthash id t pi-rpc-tree--collapsed)))
    (let ((line (line-number-at-pos)))
      (pi-rpc-tree-refresh)
      (goto-char (point-min))
      (forward-line (1- line)))))

(defvar pi-rpc-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'pi-rpc-tree-navigate)
    (define-key map (kbd "M-RET") #'pi-rpc-tree-navigate-with-summary)
    (define-key map (kbd "C-c C-s") #'pi-rpc-tree-navigate-with-summary)
    (define-key map (kbd "o") #'pi-rpc-tree-inspect-entry)
    (define-key map (kbd "S") #'pi-rpc-tree-navigate-with-summary)
    (define-key map (kbd "s") #'pi-rpc-tree-navigate-with-summary)
    (define-key map (kbd "TAB") #'pi-rpc-tree-toggle-fold)
    (define-key map (kbd "<tab>") #'pi-rpc-tree-toggle-fold)
    (define-key map (kbd "v") #'pi-rpc-tree-toggle-evidence)
    (define-key map (kbd "r") #'pi-rpc-tree-refresh)
    (define-key map (kbd "g") #'pi-rpc-tree-refresh)
    (define-key map (kbd "q") #'pi-rpc-tree-restore-chat)
    map)
  "Keymap for `pi-rpc-tree-mode'.")

(define-derived-mode pi-rpc-tree-mode special-mode "Pi-Tree"
  "Major mode for browsing a Pi session tree."
  (setq-local truncate-lines t)
  (setq-local pi-rpc-tree--show-evidence pi-rpc-tree-show-evidence))

(with-eval-after-load 'evil
  (evil-define-key '(normal motion emacs) pi-rpc-tree-mode-map
    (kbd "RET") #'pi-rpc-tree-navigate
    (kbd "<return>") #'pi-rpc-tree-navigate
    (kbd "M-RET") #'pi-rpc-tree-navigate-with-summary
    (kbd "C-c C-s") #'pi-rpc-tree-navigate-with-summary
    (kbd "o") #'pi-rpc-tree-inspect-entry
    (kbd "S") #'pi-rpc-tree-navigate-with-summary
    (kbd "s") #'pi-rpc-tree-navigate-with-summary
    (kbd "TAB") #'pi-rpc-tree-toggle-fold
    (kbd "<tab>") #'pi-rpc-tree-toggle-fold
    (kbd "v") #'pi-rpc-tree-toggle-evidence
    (kbd "r") #'pi-rpc-tree-refresh
    (kbd "g") #'pi-rpc-tree-refresh
    (kbd "q") #'pi-rpc-tree-restore-chat)
  (add-hook 'pi-rpc-tree-mode-hook #'evil-normalize-keymaps))

(defun pi-rpc-tree--session-file (chat-buf)
  "Return session file for CHAT-BUF.
Prefer cached Emacs state.  A short synchronous fallback is only used when the
state has not been populated yet, to avoid making tree open feel frozen."
  (when (buffer-live-p chat-buf)
    (with-current-buffer chat-buf
      (or (plist-get pi-coding-agent--state :session-file)
          (when-let* ((proc (pi-coding-agent--get-process)))
            (let* ((response (ignore-errors (pi-coding-agent--rpc-sync proc '(:type "get_state") 1)))
                   (data (plist-get response :data)))
              (plist-get data :session-file)))))))

(defun pi-rpc-tree-open ()
  "Open the native Emacs Pi tree view, replacing the visible Pi chat window."
  (interactive)
  (let* ((chat-buf (pi-coding-agent--get-chat-buffer))
         (input-buf (pi-coding-agent--get-input-buffer))
         (proc (and (buffer-live-p chat-buf)
                    (with-current-buffer chat-buf
                      (pi-coding-agent--get-process))))
         (session-file (and chat-buf (pi-rpc-tree--session-file chat-buf))))
    (unless (buffer-live-p chat-buf)
      (user-error "No Pi chat buffer"))
    (unless (and proc (process-live-p proc))
      (user-error "No live Pi process"))
    (unless (and session-file (file-exists-p session-file))
      (user-error "Pi session is not persisted yet"))
    (when (and (fboundp 'pi-coding-agent--session-transition-ready-p)
               (not (pi-coding-agent--session-transition-ready-p chat-buf "open tree")))
      (user-error "Pi is busy"))
    (let* ((tree-buf (get-buffer-create (format "*Pi Tree: %s*" (file-name-nondirectory session-file))))
           (chat-win (or (get-buffer-window chat-buf nil) (selected-window))))
      (with-current-buffer tree-buf
        (pi-rpc-tree-mode)
        (setq pi-rpc-tree--chat-buffer chat-buf
              pi-rpc-tree--input-buffer input-buf
              pi-rpc-tree--process proc
              pi-rpc-tree--session-file session-file
              pi-rpc-tree--collapsed (or pi-rpc-tree--collapsed (make-hash-table :test 'equal))
              pi-rpc-tree--expanded-evidence-groups (or pi-rpc-tree--expanded-evidence-groups
                                                     (make-hash-table :test 'equal)))
        (pi-rpc-tree-refresh))
      (set-window-buffer chat-win tree-buf)
      (select-window chat-win)
      (pi-rpc-tree--tree-command-loaded-async
       proc
       (lambda (command-name)
         (unless command-name
           (message "Pi tree: current Pi process did not load /%s; restart Pi with SPC o q, then SPC o p before navigating"
                    pi-rpc-tree-rpc-command-name)))))))

(defun pi-rpc-tree--schedule-chat-refresh (&optional leaf-id leaf-known-p)
  "Refresh the current Pi chat buffer soon.
When LEAF-KNOWN-P is non-nil, remember LEAF-ID as the best-known leaf for this
session.  LEAF-ID may be nil, which represents Pi's root/no-entry leaf."
  (when (derived-mode-p 'pi-coding-agent-chat-mode)
    (let ((chat-buf (current-buffer))
          (proc pi-coding-agent--process)
          (session-file (plist-get pi-coding-agent--state :session-file)))
      (when (and session-file leaf-known-p)
        (pi-rpc-tree--remember-leaf session-file leaf-id))
      (run-at-time
       0.05 nil
       (lambda ()
         (when (and (buffer-live-p chat-buf) proc (process-live-p proc))
           (pi-rpc-tree--refresh-chat proc chat-buf)))))))

(defun pi-rpc-tree--handle-session-tree-event (event)
  "Refresh chat when Pi reports a session_tree EVENT."
  (when (equal (plist-get event :type) "session_tree")
    (pi-rpc-tree--schedule-chat-refresh (plist-get event :newLeafId) t)))

(defun pi-rpc-tree--parse-rpc-tree-event (message)
  "Parse rpc-tree machine-readable MESSAGE, returning a plist or nil."
  (when (and (stringp message)
             (string-prefix-p pi-rpc-tree-rpc-event-prefix message))
    (condition-case err
        (json-parse-string
         (string-remove-prefix pi-rpc-tree-rpc-event-prefix message)
         :object-type 'plist
         :array-type 'list
         :null-object nil
         :false-object :json-false)
      (json-error
       (message "Pi tree: invalid rpc-tree event: %s" (error-message-string err))
       nil))))

(defun pi-rpc-tree--event-process ()
  "Return current Pi process while handling an event in a chat buffer."
  (and (boundp 'pi-coding-agent--process) pi-coding-agent--process))

(defun pi-rpc-tree--payload-new-leaf-known-p (payload)
  "Return non-nil when PAYLOAD explicitly reports newLeafId."
  (plist-member payload :newLeafId))

(defun pi-rpc-tree--payload-new-leaf (payload)
  "Return PAYLOAD newLeafId, which may be nil for the root leaf."
  (plist-get payload :newLeafId))

(defun pi-rpc-tree--pending-matches-p (pending payload)
  "Return non-nil when PENDING corresponds to rpc-tree PAYLOAD."
  (and pending
       (equal (plist-get pending :target-id)
              (plist-get payload :targetId))))

(defun pi-rpc-tree--remember-payload-leaf (session-file payload)
  "Remember PAYLOAD's authoritative leaf for SESSION-FILE when present."
  (when (and session-file (pi-rpc-tree--payload-new-leaf-known-p payload))
    (pi-rpc-tree--remember-leaf session-file (pi-rpc-tree--payload-new-leaf payload))))

(defun pi-rpc-tree--rpc-event-context (payload pending)
  "Return normalized context for rpc-tree PAYLOAD and optional PENDING request."
  (let ((matched-p (pi-rpc-tree--pending-matches-p pending payload)))
    (list :matched-p matched-p
          :session-file (if matched-p
                            (plist-get pending :session-file)
                          (and (boundp 'pi-coding-agent--state)
                               (plist-get pi-coding-agent--state :session-file)))
          :leaf-known-p (pi-rpc-tree--payload-new-leaf-known-p payload)
          :new-leaf (pi-rpc-tree--payload-new-leaf payload)
          :target-id (plist-get payload :targetId))))

(defun pi-rpc-tree--handle-rpc-tree-navigated (payload proc pending)
  "Handle a successful rpc-tree navigation PAYLOAD."
  (let* ((context (pi-rpc-tree--rpc-event-context payload pending))
         (matched-p (plist-get context :matched-p))
         (session-file (plist-get context :session-file))
         (leaf-known-p (plist-get context :leaf-known-p))
         (new-leaf (plist-get context :new-leaf))
         (target-id (plist-get context :target-id)))
    (pi-rpc-tree--remember-payload-leaf session-file payload)
    (if matched-p
        (let ((tree-buf (plist-get pending :tree-buf))
              (chat-buf (plist-get pending :chat-buf))
              (input-buf (plist-get pending :input-buf))
              (editor-text (plist-get pending :editor-text)))
          (pi-rpc-tree--clear-pending-rpc-navigation proc target-id)
          (pi-rpc-tree--set-input-text input-buf editor-text)
          (pi-rpc-tree--restore-chat-buffers chat-buf input-buf tree-buf)
          (pi-rpc-tree--refresh-chat
           proc chat-buf
           (lambda ()
             (pi-rpc-tree--refresh-tree-buffer-with-leaf
              tree-buf session-file new-leaf leaf-known-p)
             (message "Pi tree: navigated to %s (leaf %s)"
                      target-id
                      (or new-leaf "root")))))
      (pi-rpc-tree--schedule-chat-refresh new-leaf leaf-known-p)
      (message "Pi tree: navigated to %s (leaf %s)"
               target-id
               (or new-leaf "root"))))
  t)

(defun pi-rpc-tree--handle-rpc-tree-not-navigated (payload proc pending)
  "Handle cancelled or failed rpc-tree navigation PAYLOAD."
  (let* ((context (pi-rpc-tree--rpc-event-context payload pending))
         (matched-p (plist-get context :matched-p))
         (session-file (plist-get context :session-file))
         (leaf-known-p (plist-get context :leaf-known-p))
         (new-leaf (plist-get context :new-leaf))
         (target-id (plist-get context :target-id))
         (kind (plist-get payload :kind)))
    (pi-rpc-tree--remember-payload-leaf session-file payload)
    (when matched-p
      (pi-rpc-tree--clear-pending-rpc-navigation proc target-id)
      (pi-rpc-tree--refresh-tree-buffer-with-leaf
       (plist-get pending :tree-buf) session-file new-leaf leaf-known-p))
    (pi-rpc-tree--schedule-chat-refresh new-leaf leaf-known-p)
    (cond
     ((equal kind "error")
      (message "Pi tree: navigation failed: %s"
               (or (plist-get payload :message) "unknown error")))
     ((equal kind "noop")
      (message "Pi tree: %s"
               (or (plist-get payload :message) "no navigation needed")))
     (t
      (message "Pi tree: navigation cancelled"))))
  t)

(defun pi-rpc-tree--handle-rpc-tree-event (payload)
  "Handle machine-readable rpc-tree PAYLOAD.
Return non-nil when PAYLOAD was recognized and consumed."
  (when payload
    (let* ((proc (pi-rpc-tree--event-process))
           (pending (pi-rpc-tree--pending-rpc-navigation proc)))
      (pcase (plist-get payload :kind)
        ("navigated" (pi-rpc-tree--handle-rpc-tree-navigated payload proc pending))
        ((or "cancelled" "error" "noop") (pi-rpc-tree--handle-rpc-tree-not-navigated payload proc pending))
        (_ nil)))))

(defun pi-rpc-tree--handle-tree-notify (event)
  "Handle rpc-tree notify EVENT.
Return non-nil when EVENT was a machine-readable event and should be hidden from
normal human notification display.  Legacy human notifications only trigger a
refresh and are not treated as leaf facts because they report target id, not
necessarily the post-navigation leaf id."
  (let* ((msg (plist-get event :message))
         (payload (pi-rpc-tree--parse-rpc-tree-event msg)))
    (cond
     (payload
      (pi-rpc-tree--handle-rpc-tree-event payload))
     ((and (stringp msg)
           (or (string-prefix-p "Tree navigated: " msg)
               (string-prefix-p "Tree navigation failed:" msg)
               (string-prefix-p "No unique tree entry matches: " msg)
               (string-prefix-p "Tree entry not found: " msg)
               (string= msg "Tree navigation cancelled")
               (string= msg "Already at this point")))
      ;; Current /rpc-tree emits these only as human companions to the
      ;; machine-readable event, which already produced the Emacs-side message.
      t)
     ((and (stringp msg)
           (string-prefix-p "Tree navigated to " msg))
      ;; Older rpc-tree versions emitted only human text.  Refresh, but do not
      ;; remember the parsed id as a leaf: for user/custom targets it is wrong.
      (pi-rpc-tree--schedule-chat-refresh)
      nil)
     (t nil))))

(defun pi-rpc-tree--extension-ui-notify-around (orig event)
  "Suppress rpc-tree machine EVENT notifications, otherwise call ORIG."
  (unless (pi-rpc-tree--handle-tree-notify event)
    (funcall orig event)))

(with-eval-after-load 'pi-coding-agent-render
  (advice-remove 'pi-coding-agent--handle-display-event
                 #'pi-rpc-tree--handle-session-tree-event)
  (advice-remove 'pi-coding-agent--extension-ui-notify
                 #'pi-rpc-tree--handle-tree-notify)
  (advice-remove 'pi-coding-agent--extension-ui-notify
                 #'pi-rpc-tree--extension-ui-notify-around)
  (advice-add 'pi-coding-agent--handle-display-event
              :after #'pi-rpc-tree--handle-session-tree-event)
  (advice-add 'pi-coding-agent--extension-ui-notify
              :around #'pi-rpc-tree--extension-ui-notify-around))

(provide 'pi-rpc-tree)
;;; pi-rpc-tree.el ends here
