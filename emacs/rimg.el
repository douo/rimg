;;; rimg.el --- Remote image data plane for Image-Dired -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: multimedia, files

;;; Commentary:

;; rimg keeps Dired and TRAMP as the remote file control plane while obtaining
;; thumbnails and previews from a per-session rimgd process over an SSH tunnel.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'image-dired)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)
(require 'url-queue)

(defvar url-http-response-status)

(defgroup rimg nil
  "Remote image acceleration for TRAMP and Image-Dired."
  :group 'multimedia)

(defconst rimg-server-version "0.1.0")
(defconst rimg-protocol-version 1)
(defconst rimg-supported-tramp-methods '("ssh" "sshx")
  "Single-hop TRAMP methods supported by rimg.")

(define-error 'rimg-protocol-error "rimg protocol error")

(defconst rimg--package-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Root of the rimg source or installed package tree.")

(defcustom rimg-server-binary-directory
  (expand-file-name "dist" rimg--package-root)
  "Local directory containing platform-specific rimgd binaries."
  :type 'directory)

(defcustom rimg-ssh-program "ssh"
  "OpenSSH client used for rimg data-plane sessions."
  :type 'string)

(defcustom rimg-bootstrap-enabled t
  "Whether rimg may install its versioned rimgd binary through TRAMP."
  :type 'boolean)

(defcustom rimg-local-cache-directory
  (expand-file-name
   "rimg-emacs/"
   (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache/")))
  "Local directory containing thumbnails returned by rimgd."
  :type 'directory)

(defcustom rimg-server-cache-directory "~/.cache/rimg/thumbs"
  "Persistent cache directory on each remote rimgd host."
  :type 'string)

(defcustom rimg-remote-cache-max-age-days 30
  "Maximum age retained by `rimg-prune-remote-cache', in days."
  :type 'integer)

(defcustom rimg-remote-cache-max-size-bytes (* 10 1024 1024 1024)
  "Maximum remote thumbnail cache size retained by the prune command."
  :type 'integer)

(defcustom rimg-connect-timeout 5.0
  "Seconds to wait for rimgd health after SSH starts."
  :type 'number)

(defcustom rimg-thumbnail-size 256
  "Maximum width and height of generated thumbnails."
  :type 'integer)

(defcustom rimg-thumbnail-jpeg-quality 82
  "JPEG quality requested for generated thumbnails."
  :type 'integer)

(defcustom rimg-preview-max-width 1920
  "Maximum width of generated preview proxies."
  :type 'integer)

(defcustom rimg-preview-max-height 1920
  "Maximum height of generated preview proxies."
  :type 'integer)

(defcustom rimg-preview-jpeg-quality 88
  "JPEG quality requested for generated preview proxies."
  :type 'integer)

(defcustom rimg-http-parallelism 6
  "Maximum number of concurrent rimg HTTP requests."
  :type 'integer)

(defcustom rimg-page-size 200
  "Maximum number of thumbnails displayed on one gallery page."
  :type 'integer)

(defcustom rimg-ssh-port-attempts 10
  "Maximum local port attempts for an SSH session."
  :type 'integer)

(defcustom rimg-debug nil
  "Whether to emit additional rimg diagnostic messages."
  :type 'boolean)

(cl-defstruct (rimg--remote (:constructor rimg--remote-create))
  method
  user
  host
  port
  localname
  prefix
  identity)

(cl-defstruct (rimg--session (:constructor rimg--session-create))
  remote
  state
  local-port
  socket-path
  binary-path
  cache-dir
  process
  capabilities
  last-used)

(defvar rimg--sessions (make-hash-table :test #'equal)
  "Map remote identities to active or reusable rimg sessions.")

(defvar-local rimg--gallery-session nil)
(defvar-local rimg--gallery-dired-buffer nil)
(defvar-local rimg--gallery-files nil)
(defvar-local rimg--gallery-page-index 0)
(defvar-local rimg--gallery-generation 0)
(defvar-local rimg--gallery-pending 0)
(defvar-local rimg--gallery-results nil)
(defvar-local rimg--gallery-next-result 0)
(defvar-local rimg--gallery-layout-width nil)

(defvar rimg-thumbnail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "]") #'rimg-next-page)
    (define-key map (kbd "[") #'rimg-previous-page)
    (define-key map (kbd "RET") #'rimg-open-preview)
    (define-key map (kbd "C-<return>") #'rimg-open-original)
    map)
  "Keymap enabled in Image-Dired buffers managed by rimg.")

(define-minor-mode rimg-thumbnail-mode
  "Minor mode for paginated rimg Image-Dired galleries."
  :lighter " rimg"
  :keymap rimg-thumbnail-mode-map)

(defconst rimg--session-transitions
  '((absent . (bootstrapping dead))
    (bootstrapping . (starting dead))
    (starting . (waiting-health dead))
    (waiting-health . (ready dead))
    (ready . (dead))
    (dead . (bootstrapping)))
  "Allowed rimg session state transitions.")

(defun rimg--session-transition (session next-state)
  "Move SESSION to NEXT-STATE if the transition is valid."
  (let* ((current (rimg--session-state session))
         (allowed (alist-get current rimg--session-transitions)))
    (unless (memq next-state allowed)
      (error "rimg: invalid session transition %s -> %s" current next-state))
    (setf (rimg--session-state session) next-state
          (rimg--session-last-used session) (float-time))
    session))

(defun rimg--attach-process-sentinel (session process)
  "Attach SSH PROCESS lifecycle handling to SESSION."
  (set-process-query-on-exit-flag process nil)
  (set-process-sentinel
   process
   (lambda (finished-process _event)
     (when (memq (process-status finished-process) '(exit signal failed))
       (unless (eq (rimg--session-state session) 'dead)
         (rimg--session-transition session 'dead)))))
  process)

(defun rimg--remote-from-path (path)
  "Parse supported remote PATH into an `rimg--remote'."
  (unless (and (stringp path) (tramp-tramp-file-p path))
    (user-error "rimg: current path is not remote"))
  (let* ((parsed (tramp-dissect-file-name path))
         (method (tramp-file-name-method parsed))
         (hop (tramp-file-name-hop parsed)))
    (unless (member method rimg-supported-tramp-methods)
      (user-error "rimg: remote method %s is not supported by the MVP" method))
    (when hop
      (user-error "rimg: multi-hop SSH is not supported by the MVP"))
    (let* ((user (tramp-file-name-user parsed))
           (host (tramp-file-name-host parsed))
           (port (tramp-file-name-port parsed))
           (localname (tramp-file-name-localname parsed))
           (prefix (file-remote-p path))
           (identity (mapconcat #'identity
                                (list method (or user "") host (or port ""))
                                "|")))
      (rimg--remote-create
       :method method
       :user user
       :host host
       :port port
       :localname localname
       :prefix prefix
       :identity identity))))

(defun rimg--server-artifact-name (operating-system architecture)
  "Return the rimgd artifact for OPERATING-SYSTEM and ARCHITECTURE."
  (unless (equal operating-system "Linux")
    (user-error "rimg: remote operating system %s is not supported" operating-system))
  (pcase architecture
    ((or "x86_64" "amd64") "rimgd-linux-amd64")
    ((or "aarch64" "arm64") "rimgd-linux-arm64")
    (_ (user-error "rimg: remote architecture %s is not supported" architecture))))

(defun rimg--server-install-localname ()
  "Return the versioned remote local name used to install rimgd."
  (format "~/.cache/rimg/bin/%s/rimgd" rimg-server-version))

(defun rimg--ssh-command (remote local-port socket-path binary-path cache-dir)
  "Build the SSH command for REMOTE and its rimgd session.
LOCAL-PORT is bound on loopback and forwarded to remote SOCKET-PATH.  The
remote command starts BINARY-PATH with CACHE-DIR."
  (let* ((target (if (rimg--remote-user remote)
                     (format "%s@%s"
                             (rimg--remote-user remote)
                             (rimg--remote-host remote))
                   (rimg--remote-host remote)))
         (forward (format "127.0.0.1:%d:%s" local-port socket-path))
         (remote-command
          (mapconcat #'shell-quote-argument
                     (list "exec" binary-path "serve"
                           "--socket" socket-path
                           "--cache-dir" cache-dir
                           "--exit-on-stdin-eof")
                     " ")))
    (append
     (list rimg-ssh-program
           "-T"
           "-o" "ExitOnForwardFailure=yes"
           "-o" "ServerAliveInterval=15"
           "-o" "ServerAliveCountMax=3"
           "-L" forward)
     (when (rimg--remote-port remote)
       (list "-p" (rimg--remote-port remote)))
     (list target remote-command))))

(defun rimg--parse-health (json)
  "Parse and validate a rimgd health response from JSON."
  (let ((health
         (condition-case error-data
             (json-parse-string json
                                :object-type 'alist
                                :array-type 'list
                                :null-object nil
                                :false-object nil)
           (error
            (signal 'rimg-protocol-error
                    (list (format "invalid health JSON: %s"
                                  (error-message-string error-data))))))))
    (unless (alist-get 'ok health)
      (signal 'rimg-protocol-error '("rimgd health is not ready")))
    (unless (equal (alist-get 'protocol health) rimg-protocol-version)
      (signal 'rimg-protocol-error
              (list (format "protocol mismatch: server=%s client=%s"
                            (alist-get 'protocol health)
                            rimg-protocol-version))))
    health))

(defun rimg--candidate-local-port ()
  "Return a candidate local port from the dynamic/private range."
  (+ 49152 (random (- 65536 49152))))

(defun rimg--remote-file-name (remote localname)
  "Build a TRAMP file name for REMOTE and LOCALNAME."
  (concat (rimg--remote-prefix remote) localname))

(defun rimg--local-thumbnail-path (remote key format)
  "Return the local cache path for REMOTE's server KEY in FORMAT."
  (unless (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" key)
    (error "rimg: invalid thumbnail cache key: %s" key))
  (let ((extension
         (pcase format
           ("jpeg" ".jpg")
           ("png" ".png")
           (_ (error "rimg: unsupported local thumbnail format: %s" format))))
        (remote-directory (rimg--local-remote-cache-directory remote)))
    (expand-file-name
     (format "%s/%s%s" (substring key 0 2) key extension)
     remote-directory)))

(defun rimg--local-remote-cache-directory (remote)
  "Return the local cache partition directory for REMOTE."
  (expand-file-name
   (secure-hash 'sha256 (rimg--remote-identity remote))
   rimg-local-cache-directory))

(defun rimg--write-local-file-atomically (path data)
  "Write DATA to local PATH atomically and return PATH."
  (let ((directory (file-name-directory path)) temporary)
    (make-directory directory t)
    (set-file-modes directory #o700)
    (setq temporary (make-temp-file (concat path ".tmp.")))
    (unwind-protect
        (let ((coding-system-for-write 'no-conversion))
          (write-region data nil temporary nil 'silent)
          (set-file-modes temporary #o600)
          (rename-file temporary path t)
          (setq temporary nil)
          path)
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun rimg--store-local-thumbnail (remote key format data)
  "Atomically store DATA for REMOTE's server KEY in FORMAT and return its path."
  (rimg--write-local-file-atomically
   (rimg--local-thumbnail-path remote key format) data))

(defun rimg--local-reference-path (remote original-localname &optional transform)
  "Return the cache reference path for REMOTE ORIGINAL-LOCALNAME and thumb spec."
  (let* ((request-key
          (secure-hash
           'sha256
           (format "%s\0%s"
                   original-localname
                   (or transform
                       (format "thumb:%dx%d:contain:jpeg:q%d"
                               rimg-thumbnail-size rimg-thumbnail-size
                               rimg-thumbnail-jpeg-quality))))))
    (expand-file-name
     (format "refs/%s/%s" (substring request-key 0 2) request-key)
     (rimg--local-remote-cache-directory remote))))

(defun rimg--cached-local-thumbnail (remote original-localname
                                            &optional transform)
  "Return (KEY . PATH) for REMOTE ORIGINAL-LOCALNAME when its local cache exists."
  (let ((reference
         (rimg--local-reference-path remote original-localname transform)))
    (when (file-readable-p reference)
      (let ((key
             (with-temp-buffer
               (insert-file-contents-literally reference)
               (string-trim (buffer-string)))))
        (condition-case nil
            (let ((path (rimg--local-thumbnail-path remote key "jpeg")))
              (when (file-regular-p path)
                (cons key path)))
          (error nil))))))

(defun rimg--response-body-start ()
  "Return the start position of the current HTTP response body."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "rimg: malformed HTTP response"))
  (point))

(defun rimg--response-header (name body-start)
  "Return HTTP header NAME before BODY-START in the current buffer."
  (save-excursion
    (save-restriction
      (narrow-to-region (point-min) body-start)
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (re-search-forward
               (format "^%s:[ \t]*\\([^\r\n]+\\)" (regexp-quote name))
               nil t)
          (string-trim (match-string-no-properties 1)))))))

(defun rimg--thumbnail-response (status remote format reference-path cached
                                        callback error-callback)
  "Handle a queued thumbnail response and invoke CALLBACK or ERROR-CALLBACK."
  (let ((response-buffer (current-buffer)))
    (unwind-protect
        (condition-case error-data
            (progn
              (when-let* ((transport-error (plist-get status :error)))
                (error "rimg: thumbnail transport failed: %s" transport-error))
              (let* ((body-start (rimg--response-body-start))
                     (key (rimg--response-header "X-Rimg-Key" body-start))
                     (not-modified
                      (rimg--response-header
                       "X-Rimg-Not-Modified" body-start)))
                (unless key
                  (error "rimg: thumbnail response omitted X-Rimg-Key"))
                (unless (equal url-http-response-status 200)
                  (error "rimg: thumbnail returned HTTP %s"
                         url-http-response-status))
                (if (equal not-modified "true")
                    (progn
                      (unless (and cached
                                   (equal key (car cached))
                                   (file-regular-p (cdr cached)))
                        (error "rimg: local thumbnail is missing for revalidation"))
                      (funcall callback (cdr cached)))
                  (let* ((data (buffer-substring-no-properties
                                body-start (point-max)))
                         (path (rimg--store-local-thumbnail
                                remote key format data)))
                    (rimg--write-local-file-atomically
                     reference-path (concat key "\n"))
                    (funcall callback path)))))
          (error
           (if error-callback
               (funcall error-callback error-data)
             (message "%s" (error-message-string error-data)))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun rimg--request-thumbnail (session original-file callback
                                        &optional error-callback)
  "Request ORIGINAL-FILE through SESSION and call CALLBACK with a local path."
  (unless (rimg--session-live-ready-p session)
    (error "rimg: thumbnail request requires a ready session"))
  (let* ((remote (rimg--session-remote session))
         (original-remote (rimg--remote-from-path original-file)))
    (unless (equal (rimg--remote-identity remote)
                   (rimg--remote-identity original-remote))
      (error "rimg: original file belongs to a different remote"))
    (let* ((original-localname (rimg--remote-localname original-remote))
           (reference-path
            (rimg--local-reference-path remote original-localname))
           (cached (rimg--cached-local-thumbnail remote original-localname))
           (url-request-method "POST")
           (url-request-extra-headers
            (append
             '(("Content-Type" . "application/json"))
             (when cached
               `(("If-None-Match" . ,(format "\"%s\"" (car cached)))))))
          (url-request-data
           (json-serialize
            `((path . ,original-localname)
              (width . ,rimg-thumbnail-size)
              (height . ,rimg-thumbnail-size)
              (fit . "contain")
              (format . "jpeg")
              (quality . ,rimg-thumbnail-jpeg-quality)))))
      (setq url-queue-parallel-processes rimg-http-parallelism)
      (url-queue-retrieve
       (format "http://127.0.0.1:%d/v1/thumb"
               (rimg--session-local-port session))
       #'rimg--thumbnail-response
       (list remote "jpeg" reference-path cached callback error-callback)
       t t))))

(defun rimg--request-preview (session original-file callback
                                      &optional error-callback)
  "Request a bounded preview for ORIGINAL-FILE and call CALLBACK with its path."
  (unless (rimg--session-live-ready-p session)
    (error "rimg: preview request requires a ready session"))
  (let* ((remote (rimg--session-remote session))
         (original-remote (rimg--remote-from-path original-file)))
    (unless (equal (rimg--remote-identity remote)
                   (rimg--remote-identity original-remote))
      (error "rimg: original file belongs to a different remote"))
    (let* ((original-localname (rimg--remote-localname original-remote))
           (transform
            (format "preview:%dx%d:contain:jpeg:q%d"
                    rimg-preview-max-width rimg-preview-max-height
                    rimg-preview-jpeg-quality))
           (reference-path
            (rimg--local-reference-path remote original-localname transform))
           (cached
            (rimg--cached-local-thumbnail remote original-localname transform))
           (url-request-method "POST")
           (url-request-extra-headers
            (append
             '(("Content-Type" . "application/json"))
             (when cached
               `(("If-None-Match" . ,(format "\"%s\"" (car cached)))))))
           (url-request-data
            (json-serialize
             `((path . ,original-localname)
               (max_width . ,rimg-preview-max-width)
               (max_height . ,rimg-preview-max-height)
               (format . "jpeg")
               (quality . ,rimg-preview-jpeg-quality)))))
      (setq url-queue-parallel-processes rimg-http-parallelism)
      (url-queue-retrieve
       (format "http://127.0.0.1:%d/v1/preview"
               (rimg--session-local-port session))
       #'rimg--thumbnail-response
       (list remote "jpeg" reference-path cached callback error-callback)
       t t))))

(defun rimg--prepare-response (status)
  "Consume a queued prepare response described by STATUS."
  (let ((response-buffer (current-buffer)))
    (unwind-protect
        (condition-case error-data
            (progn
              (when-let* ((transport-error (plist-get status :error)))
                (error "rimg: prepare transport failed: %s" transport-error))
              (unless (equal url-http-response-status 200)
                (error "rimg: prepare returned HTTP %s"
                       url-http-response-status)))
          (error
           (message "%s" (error-message-string error-data))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun rimg--request-prepare (session files)
  "Queue remote thumbnail preparation for FILES through SESSION."
  (unless (rimg--session-live-ready-p session)
    (error "rimg: prepare requires a ready session"))
  (let ((remote (rimg--session-remote session)) localnames)
    (dolist (file files)
      (let ((file-remote (rimg--remote-from-path file)))
        (unless (equal (rimg--remote-identity remote)
                       (rimg--remote-identity file-remote))
          (error "rimg: prepare file belongs to a different remote"))
        (push (rimg--remote-localname file-remote) localnames)))
    (let ((url-request-method "POST")
          (url-request-extra-headers
           '(("Content-Type" . "application/json")))
          (url-request-data
           (json-serialize
            `((files . ,(vconcat (nreverse localnames)))
              (thumbnail
               . ((width . ,rimg-thumbnail-size)
                  (height . ,rimg-thumbnail-size)
                  (format . "jpeg")
                  (quality . ,rimg-thumbnail-jpeg-quality)))))))
      (setq url-queue-parallel-processes rimg-http-parallelism)
      (url-queue-retrieve
       (format "http://127.0.0.1:%d/v1/prepare"
               (rimg--session-local-port session))
       #'rimg--prepare-response nil t t))))

(defun rimg--gallery-page-files ()
  "Return the files for the current rimg gallery page."
  (let* ((start (* rimg--gallery-page-index rimg-page-size))
         (end (min (length rimg--gallery-files) (+ start rimg-page-size))))
    (if (< start end)
        (seq-subseq rimg--gallery-files start end)
      nil)))

(defun rimg--gallery-page-count ()
  "Return the number of pages in the current rimg gallery."
  (/ (+ (length rimg--gallery-files) rimg-page-size -1) rimg-page-size))

(defun rimg--gallery-cell-size ()
  "Return the fixed pixel size reserved for one rimg thumbnail cell."
  (+ rimg-thumbnail-size
     (* 2 image-dired-thumb-relief)
     (* 2 image-dired-thumb-margin)))

(defun rimg--gallery-placeholder (index original dired-buffer)
  "Return slot INDEX's stable placeholder for ORIGINAL from DIRED-BUFFER."
  (let ((cell-size (rimg--gallery-cell-size)))
    (propertize
     " "
     'display `(space :width (,cell-size) :height (,cell-size))
     'image-dired-thumbnail t
     'rimg-gallery-slot index
     'rimg-thumbnail-pending t
     'original-file-name original
     'associated-dired-buffer dired-buffer
     'help-echo (file-name-nondirectory original))))

(defun rimg--gallery-line-up (window)
  "Line up the current rimg gallery for WINDOW when its width changed."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (let ((width (window-body-width window t)))
      (unless (equal width rimg--gallery-layout-width)
        (setq rimg--gallery-layout-width width)
        (let* ((start (copy-marker (window-start window)))
               (selected-original
                (get-text-property (point) 'original-file-name))
               (start-original
                (get-text-property (window-start window) 'original-file-name)))
          (unwind-protect
              (progn
                (save-excursion
                  (image-dired--line-up-with-method))
                (when selected-original
                  (when-let* ((position
                               (text-property-any
                                (point-min) (point-max)
                                'original-file-name selected-original)))
                    (goto-char position)))
                (if-let* ((position
                           (and start-original
                                (text-property-any
                                 (point-min) (point-max)
                                 'original-file-name start-original))))
                    (set-window-start window position t)
                  (set-window-start window start t)))
            (set-marker start nil)))))))

(defun rimg--gallery-window-size-changed (window)
  "Reflow the current rimg gallery after WINDOW changes size."
  (when rimg-thumbnail-mode
    (rimg--gallery-line-up window)))

(defun rimg--gallery-queue-result (buffer generation index commit)
  "Queue COMMIT for INDEX in BUFFER's GENERATION and flush it in file order."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (= generation rimg--gallery-generation)
                 (< index (length rimg--gallery-results)))
        (let ((selected-original
               (get-text-property (point) 'original-file-name)))
          (aset rimg--gallery-results index commit)
          (while-let ((next (and (< rimg--gallery-next-result
                                    (length rimg--gallery-results))
                                 (aref rimg--gallery-results
                                       rimg--gallery-next-result))))
            (aset rimg--gallery-results rimg--gallery-next-result nil)
            (setq rimg--gallery-next-result (1+ rimg--gallery-next-result))
            (funcall next))
          (when selected-original
            (when-let* ((position
                         (text-property-any
                          (point-min) (point-max)
                          'original-file-name selected-original)))
              (goto-char position))))))))

(defun rimg--gallery-request-finished (buffer generation)
  "Record one completed request for BUFFER's GENERATION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation rimg--gallery-generation)
        (setq rimg--gallery-pending (1- rimg--gallery-pending))))))

(defun rimg--gallery-thumbnail-ready (buffer marker generation original
                                             dired-buffer thumbnail)
  "Replace MARKER in BUFFER with THUMBNAIL associated with ORIGINAL."
  (when (and (buffer-live-p buffer) (marker-buffer marker))
    (with-current-buffer buffer
      (when (= generation rimg--gallery-generation)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char marker)
            (delete-char 1)
            (image-dired-insert-thumbnail thumbnail original dired-buffer)))
        (set-marker marker nil)
        (rimg--gallery-request-finished buffer generation)))))

(defun rimg--gallery-thumbnail-error (buffer marker generation error-data)
  "Replace a failed thumbnail at MARKER with a compact error indicator."
  (when (and (buffer-live-p buffer) (marker-buffer marker))
    (with-current-buffer buffer
      (when (= generation rimg--gallery-generation)
        (let ((inhibit-read-only t)
              (properties (text-properties-at marker)))
          (save-excursion
            (goto-char marker)
            (delete-char 1)
            (setq properties (plist-put properties 'rimg-thumbnail-pending nil)
                  properties (plist-put properties 'rimg-thumbnail-error t)
                  properties (plist-put properties 'face 'error)
                  properties (plist-put properties 'help-echo
                                        (error-message-string error-data)))
            (insert (apply #'propertize "!" properties))))
        (set-marker marker nil)
        (rimg--gallery-request-finished buffer generation)))))

(defun rimg--render-gallery-page (buffer)
  "Render BUFFER's current rimg gallery page."
  (let (jobs generation page-files session)
    (with-current-buffer buffer
      (setq rimg--gallery-generation (1+ rimg--gallery-generation)
            generation rimg--gallery-generation)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq page-files (rimg--gallery-page-files)
              session rimg--gallery-session)
        (setq-local image-dired-thumbnail-storage 'image-dired)
        (setq-local image-dired-thumb-size rimg-thumbnail-size)
        (setq-local image-dired-line-up-method 'dynamic)
        (setq image-dired--number-of-thumbnails (length page-files)
              rimg--gallery-results (make-vector (length page-files) nil)
              rimg--gallery-next-result 0
              rimg--gallery-layout-width nil)
        (cl-loop for original in page-files
                 for index from 0
                 do
                 (insert (rimg--gallery-placeholder
                          index original rimg--gallery-dired-buffer)
                         " ")
                 (push (list index original) jobs)))
      (setq jobs (nreverse jobs)
            rimg--gallery-pending (length jobs)))
    (pop-to-buffer buffer)
    (when-let* ((window (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (rimg--gallery-line-up window)))
    ;; Create markers only after the initial layout.  Image-Dired deletes and
    ;; reinserts separators while lining up, which can move earlier markers.
    (with-current-buffer buffer
      (setq jobs
            (mapcar
             (lambda (job)
               (pcase-let ((`(,index ,original) job))
                 (let ((position
                        (text-property-any
                         (point-min) (point-max) 'rimg-gallery-slot index)))
                   (unless position
                     (error "rimg: gallery slot %d disappeared during layout"
                            index))
                   (list index (copy-marker position) original))))
             jobs)))
    (dolist (job jobs)
      (pcase-let ((`(,index ,marker ,original) job))
        (rimg--request-thumbnail
         (buffer-local-value 'rimg--gallery-session buffer)
         original
         (lambda (thumbnail)
           (rimg--gallery-queue-result
            buffer generation index
            (lambda ()
              (rimg--gallery-thumbnail-ready
               buffer marker generation original
               (buffer-local-value 'rimg--gallery-dired-buffer buffer)
               thumbnail))))
         (lambda (error-data)
           (rimg--gallery-queue-result
            buffer generation index
            (lambda ()
              (rimg--gallery-thumbnail-error
               buffer marker generation error-data)))))))
    (when (and page-files
               (or (null (rimg--session-capabilities session))
                   (alist-get 'prepare (rimg--session-capabilities session))))
      (rimg--request-prepare session page-files))
    buffer))

(defun rimg--display-gallery (session dired-buffer files)
  "Display FILES from DIRED-BUFFER through SESSION and return the gallery buffer."
  (let ((buffer (image-dired-create-thumbnail-buffer)))
    (with-current-buffer buffer
      (setq rimg--gallery-session session
            rimg--gallery-dired-buffer dired-buffer
            rimg--gallery-files files
            rimg--gallery-page-index 0)
      (rimg-thumbnail-mode 1)
      (add-hook 'window-size-change-functions
                #'rimg--gallery-window-size-changed nil t))
    (rimg--render-gallery-page buffer)))

(defun rimg-next-page ()
  "Display the next page in the current rimg gallery."
  (interactive nil image-dired-thumbnail-mode)
  (unless (and rimg-thumbnail-mode rimg--gallery-files)
    (user-error "rimg: this is not an rimg gallery"))
  (when (>= (1+ rimg--gallery-page-index) (rimg--gallery-page-count))
    (user-error "rimg: already on the last page"))
  (setq rimg--gallery-page-index (1+ rimg--gallery-page-index))
  (rimg--render-gallery-page (current-buffer)))

(defun rimg-previous-page ()
  "Display the previous page in the current rimg gallery."
  (interactive nil image-dired-thumbnail-mode)
  (unless (and rimg-thumbnail-mode rimg--gallery-files)
    (user-error "rimg: this is not an rimg gallery"))
  (when (zerop rimg--gallery-page-index)
    (user-error "rimg: already on the first page"))
  (setq rimg--gallery-page-index (1- rimg--gallery-page-index))
  (rimg--render-gallery-page (current-buffer)))

(defun rimg--dired-image-files ()
  "Return image files from the current Dired listing without relisting it."
  (unless (derived-mode-p 'dired-mode)
    (user-error "rimg: current buffer is not Dired"))
  (let ((case-fold-search t) files)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((directory-line (looking-at-p dired-re-dir))
              (file (dired-get-filename nil t)))
          (when (and file
                     (not directory-line)
                     (string-match-p (image-dired--file-name-regexp) file))
            (push file files)))
        (forward-line 1)))
    (nreverse files)))

(defun rimg--remote-expanded-localname (remote localname)
  "Expand remote LOCALNAME and return its absolute remote-local path."
  (file-remote-p
   (expand-file-name (rimg--remote-file-name remote localname))
   'localname))

(defun rimg--remote-process-output (remote program &rest arguments)
  "Run PROGRAM with ARGUMENTS on REMOTE and return trimmed stdout."
  (with-temp-buffer
    (let* ((default-directory (rimg--remote-file-name remote "~/"))
           (status (apply #'process-file program nil (current-buffer) nil arguments))
           (output (string-trim (buffer-string))))
      (unless (and (integerp status) (zerop status))
        (error "rimg: remote command failed (%s): %s" status output))
      output)))

(defun rimg--detect-server-artifact (remote)
  "Detect REMOTE platform and return its local rimgd artifact name."
  (rimg--server-artifact-name
   (rimg--remote-process-output remote "uname" "-s")
   (rimg--remote-process-output remote "uname" "-m")))

(defun rimg--local-server-artifact (remote)
  "Return the local rimgd artifact path suitable for REMOTE."
  (let ((artifact (expand-file-name
                   (rimg--detect-server-artifact remote)
                   rimg-server-binary-directory)))
    (unless (file-readable-p artifact)
      (error "rimg: server artifact is missing: %s (run `make dist')" artifact))
    artifact))

(defun rimg--installed-server-current-p (remote binary-localname)
  "Return non-nil when REMOTE BINARY-LOCALNAME matches this client."
  (let ((remote-file (rimg--remote-file-name remote binary-localname)))
    (and
     (file-executable-p remote-file)
     (condition-case nil
         (let ((version
                (json-parse-string
                 (rimg--remote-process-output
                  remote binary-localname "version" "--json")
                 :object-type 'alist)))
           (and (equal (alist-get 'version version) rimg-server-version)
                (equal (alist-get 'protocol version) rimg-protocol-version)))
       (error nil)))))

(defun rimg--install-server (remote local-artifact binary-localname)
  "Atomically install LOCAL-ARTIFACT on REMOTE as BINARY-LOCALNAME."
  (unless rimg-bootstrap-enabled
    (error "rimg: remote rimgd is missing or incompatible and bootstrap is disabled"))
  (let* ((remote-file (rimg--remote-file-name remote binary-localname))
         (remote-directory (file-name-directory remote-file))
         (temporary (format "%s.tmp.%s" remote-file (rimg--session-id))))
    (make-directory remote-directory t)
    (unwind-protect
        (progn
          (copy-file local-artifact temporary t)
          (set-file-modes temporary #o755)
          (rename-file temporary remote-file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun rimg--ensure-server (remote)
  "Return the absolute remote-local rimgd path for REMOTE, installing if needed."
  (let* ((binary-localname
          (rimg--remote-expanded-localname remote (rimg--server-install-localname)))
         (local-artifact nil))
    (unless (rimg--installed-server-current-p remote binary-localname)
      (setq local-artifact (rimg--local-server-artifact remote))
      (rimg--install-server remote local-artifact binary-localname)
      (unless (rimg--installed-server-current-p remote binary-localname)
        (error "rimg: installed rimgd failed version verification")))
    binary-localname))

(defun rimg--session-id ()
  "Return a short unique identifier suitable for a Unix socket name."
  (substring
   (secure-hash 'sha256
                (format "%s:%s:%s:%s"
                        (emacs-pid) (float-time) (random) (recent-keys)))
   0 12))

(defconst rimg--runtime-directory-script
  (concat
   "set -eu; uid=$(id -u); "
   "if [ -n \"${XDG_RUNTIME_DIR:-}\" ] && [ -d \"$XDG_RUNTIME_DIR\" ]; then "
   "base=\"${XDG_RUNTIME_DIR%/}/rimg\"; "
   "elif [ -n \"${TMPDIR:-}\" ]; then base=\"${TMPDIR%/}/rimg-$uid\"; "
   "else base=\"/tmp/rimg-$uid\"; fi; "
   "case \"$base\" in /*) ;; *) base=\"/tmp/rimg-$uid\" ;; esac; "
   "if [ ${#base} -gt 70 ]; then base=\"/tmp/rimg-$uid\"; fi; "
   "umask 077; mkdir -p -- \"$base\"; chmod 700 -- \"$base\"; printf %s \"$base\"")
  "Remote shell script that creates and prints a private short runtime path.")

(defun rimg--remote-runtime-directory (remote)
  "Create and return REMOTE's private rimg runtime directory."
  (rimg--remote-process-output remote "sh" "-c" rimg--runtime-directory-script))

(defun rimg--ssh-log-buffer (remote)
  "Return the SSH log buffer for REMOTE."
  (get-buffer-create (format "*rimg-ssh:%s*" (rimg--remote-host remote))))

(defun rimg--start-ssh-process (session)
  "Start the SSH process for SESSION and return it."
  (let* ((remote (rimg--session-remote session))
         (command (rimg--ssh-command
                   remote
                   (rimg--session-local-port session)
                   (rimg--session-socket-path session)
                   (rimg--session-binary-path session)
                   (rimg--session-cache-dir session)))
         (log-buffer (rimg--ssh-log-buffer remote))
         (process-connection-type nil)
         process)
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n[%s] %S\n" (current-time-string) command))))
    (setq process
          (apply #'start-process
                 (format "rimg-ssh:%s:%s"
                         (rimg--remote-host remote)
                         (rimg--session-local-port session))
                 log-buffer
                 (car command)
                 (cdr command)))
    (setf (rimg--session-process session) process)
    (rimg--attach-process-sentinel session process)
    process))

(defun rimg--request-health (session)
  "Request and validate health for SESSION synchronously."
  (let* ((url-proxy-services nil)
         (url-request-method "GET")
         (url (format "http://127.0.0.1:%d/v1/health"
                      (rimg--session-local-port session)))
         (buffer (url-retrieve-synchronously url t t 0.3)))
    (unless buffer
      (error "rimg: health request timed out"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (equal url-http-response-status 200)
            (error "rimg: health returned HTTP %s" url-http-response-status))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "rimg: malformed health response"))
          (rimg--parse-health
           (buffer-substring-no-properties (point) (point-max))))
      (kill-buffer buffer))))

(defun rimg--wait-for-health (session)
  "Poll SESSION health until ready or `rimg-connect-timeout' expires."
  (let ((deadline (+ (float-time) rimg-connect-timeout))
        (delay 0.05)
        (last-error nil)
        health)
    (while (and (not health) (< (float-time) deadline))
      (unless (process-live-p (rimg--session-process session))
        (error "rimg: SSH exited before rimgd became ready; see %s"
               (buffer-name (rimg--ssh-log-buffer (rimg--session-remote session)))))
      (condition-case error-data
          (setq health (rimg--request-health session))
        (error (setq last-error error-data)))
      (unless health
        (accept-process-output (rimg--session-process session) delay)
        (setq delay (min 0.4 (* delay 2)))))
    (or health
        (signal (car last-error)
                (or (cdr last-error) '("rimgd health timeout"))))))

(defun rimg--session-live-ready-p (session)
  "Return non-nil when SESSION can be reused."
  (and session
       (eq (rimg--session-state session) 'ready)
       (process-live-p (rimg--session-process session))))

(defun rimg--connect-remote (remote)
  "Bootstrap and connect a reusable rimg SESSION for REMOTE."
  (let ((existing (gethash (rimg--remote-identity remote) rimg--sessions)))
    (if (rimg--session-live-ready-p existing)
        (progn
          (setf (rimg--session-last-used existing) (float-time))
          existing)
      (let ((session (or existing
                         (rimg--session-create :remote remote :state 'absent))))
        (setf (rimg--session-remote session) remote)
        (puthash (rimg--remote-identity remote) session rimg--sessions)
        (when (and existing
                   (not (memq (rimg--session-state session) '(absent dead))))
          (rimg--disconnect-session session))
        (rimg--session-transition session 'bootstrapping)
        (condition-case error-data
            (let* ((binary (rimg--ensure-server remote))
                   (runtime-directory (rimg--remote-runtime-directory remote))
                   (socket-path (format "%s/%s.sock"
                                        runtime-directory (rimg--session-id)))
                   (cache-dir (rimg--remote-expanded-localname
                               remote rimg-server-cache-directory))
                   (attempt 0)
                   (connected nil))
              (when (> (string-bytes socket-path) 100)
                (error "rimg: remote Unix socket path is too long: %s" socket-path))
              (setf (rimg--session-binary-path session) binary
                    (rimg--session-socket-path session) socket-path
                    (rimg--session-cache-dir session) cache-dir)
              (while (and (not connected) (< attempt rimg-ssh-port-attempts))
                (setq attempt (1+ attempt))
                (when (eq (rimg--session-state session) 'dead)
                  (rimg--session-transition session 'bootstrapping))
                (setf (rimg--session-local-port session)
                      (rimg--candidate-local-port))
                (rimg--session-transition session 'starting)
                (rimg--start-ssh-process session)
                (rimg--session-transition session 'waiting-health)
                (condition-case attempt-error
                    (let ((health (rimg--wait-for-health session)))
                      (setf (rimg--session-capabilities session)
                            (alist-get 'capabilities health))
                      (rimg--session-transition session 'ready)
                      (setq connected t))
                  (error
                   (when (process-live-p (rimg--session-process session))
                     (delete-process (rimg--session-process session))
                     (accept-process-output (rimg--session-process session) 0.05))
                   (unless (eq (rimg--session-state session) 'dead)
                     (rimg--session-transition session 'dead))
                   (when (or (= attempt rimg-ssh-port-attempts)
                             (not (string-match-p
                                   "SSH exited before"
                                   (error-message-string attempt-error))))
                     (signal (car attempt-error) (cdr attempt-error))))))
              (unless connected
                (error "rimg: exhausted SSH local port attempts"))
              session)
          (error
           (unless (eq (rimg--session-state session) 'dead)
             (rimg--session-transition session 'dead))
           (signal (car error-data) (cdr error-data))))))))

(defun rimg--disconnect-session (session)
  "Stop SESSION and mark it dead."
  (when-let* ((process (rimg--session-process session)))
    (when (process-live-p process)
      (delete-process process)
      (accept-process-output process 0.1)))
  (unless (eq (rimg--session-state session) 'dead)
    (rimg--session-transition session 'dead))
  session)

(defun rimg-connect (&optional directory)
  "Connect rimg for remote DIRECTORY or `default-directory'."
  (interactive)
  (let* ((remote (rimg--remote-from-path (or directory default-directory)))
         (session (rimg--connect-remote remote)))
    (message "rimg: connected to %s on local port %d"
             (rimg--remote-host remote)
             (rimg--session-local-port session))
    session))

(defun rimg-disconnect (&optional directory)
  "Disconnect rimg for remote DIRECTORY or `default-directory'."
  (interactive)
  (let* ((remote (rimg--remote-from-path (or directory default-directory)))
         (session (gethash (rimg--remote-identity remote) rimg--sessions)))
    (when session
      (rimg--disconnect-session session)
      (message "rimg: disconnected from %s" (rimg--remote-host remote)))))

(defun rimg-reconnect (&optional directory)
  "Reconnect rimg for remote DIRECTORY or `default-directory'."
  (interactive)
  (rimg-disconnect directory)
  (rimg-connect directory))

(defun rimg-dired ()
  "Display a paginated rimg gallery for the current remote Dired buffer."
  (interactive nil dired-mode)
  (unless (derived-mode-p 'dired-mode)
    (user-error "rimg: current buffer is not Dired"))
  (let* ((dired-buffer (current-buffer))
         (remote (rimg--remote-from-path default-directory))
         (files (rimg--dired-image-files)))
    (unless files
      (user-error "rimg: current Dired listing contains no images"))
    (rimg--display-gallery
     (rimg--connect-remote remote) dired-buffer files)))

(defun rimg-open-preview ()
  "Display a bounded local preview for the rimg thumbnail at point."
  (interactive nil image-dired-thumbnail-mode)
  (unless (and rimg-thumbnail-mode rimg--gallery-session)
    (user-error "rimg: this is not an rimg gallery"))
  (let ((original (image-dired-original-file-name)))
    (unless original
      (user-error "rimg: no thumbnail at point"))
    (rimg--request-preview
     rimg--gallery-session original
     #'image-dired-display-image
     (lambda (error-data)
       (message "%s" (error-message-string error-data))))))

(defun rimg-open-original ()
  "Explicitly display the TRAMP original for the rimg thumbnail at point."
  (interactive nil image-dired-thumbnail-mode)
  (let ((original (image-dired-original-file-name)))
    (unless original
      (user-error "rimg: no thumbnail at point"))
    (image-dired-display-image original)))

(defun rimg--current-remote ()
  "Return the rimg remote associated with the current buffer."
  (cond
   ((and rimg-thumbnail-mode rimg--gallery-session)
    (rimg--session-remote rimg--gallery-session))
   ((tramp-tramp-file-p default-directory)
    (rimg--remote-from-path default-directory))
   (t
    (user-error "rimg: current buffer is not associated with a remote"))))

(defun rimg-clear-local-cache ()
  "Clear the local rimg cache partition for the current remote."
  (interactive)
  (let* ((remote (rimg--current-remote))
         (directory (rimg--local-remote-cache-directory remote)))
    (when (file-directory-p directory)
      (delete-directory directory t))
    (message "rimg: cleared local cache for %s" (rimg--remote-host remote))))

(defun rimg--current-session ()
  "Return or establish the rimg session associated with the current buffer."
  (if (and rimg-thumbnail-mode rimg--gallery-session)
      rimg--gallery-session
    (let* ((remote (rimg--current-remote))
           (session (gethash (rimg--remote-identity remote) rimg--sessions)))
      (if (rimg--session-live-ready-p session)
          session
        (rimg--connect-remote remote)))))

(defun rimg-prune-remote-cache ()
  "Prune the persistent rimgd cache for the current remote."
  (interactive)
  (let* ((session (rimg--current-session))
         (remote (rimg--session-remote session))
         (output
          (rimg--remote-process-output
           remote
           (rimg--session-binary-path session)
           "prune"
           "--cache-dir" (rimg--session-cache-dir session)
           "--max-age" (format "%dh" (* rimg-remote-cache-max-age-days 24))
           "--max-size-bytes" (number-to-string
                                rimg-remote-cache-max-size-bytes)
           "--json"))
         (result (json-parse-string output :object-type 'alist)))
    (message "rimg: pruned %s files (%s bytes) on %s"
             (alist-get 'removed_files result)
             (alist-get 'freed_bytes result)
             (rimg--remote-host remote))
    result))

(provide 'rimg)

;;; rimg.el ends here
