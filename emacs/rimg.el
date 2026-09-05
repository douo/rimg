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
(require 'rbridge)
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

(defcustom rimg-gallery-prefetch-rows 2
  "Number of rows to preload above and below the visible gallery rows."
  :type 'integer)

(defcustom rimg-ssh-port-attempts 10
  "Maximum local port attempts for an SSH session."
  :type 'integer)

(defcustom rimg-debug nil
  "Whether to emit additional rimg diagnostic messages."
  :type 'boolean)

;; Compatibility aliases preserve the private API used by the original rimg
;; tests and configurations while the actual transport records live in
;; rbridge.
(defalias 'rimg--remote-create #'rbridge-remote-create)
(defalias 'rimg--remote-method #'rbridge-remote-method)
(defalias 'rimg--remote-user #'rbridge-remote-user)
(defalias 'rimg--remote-host #'rbridge-remote-host)
(defalias 'rimg--remote-port #'rbridge-remote-port)
(defalias 'rimg--remote-localname #'rbridge-remote-localname)
(defalias 'rimg--remote-prefix #'rbridge-remote-prefix)
(defalias 'rimg--remote-identity #'rbridge-remote-identity)

(defalias 'rimg--session-create #'rbridge-session-create)
(defalias 'rimg--session-remote #'rbridge-session-remote)
(defalias 'rimg--session-state #'rbridge-session-state)
(defalias 'rimg--session-local-port #'rbridge-session-local-port)
(defalias 'rimg--session-socket-path #'rbridge-session-socket-path)
(defalias 'rimg--session-binary-path #'rbridge-session-binary-path)
(defalias 'rimg--session-cache-dir #'rbridge-session-cache-dir)
(defalias 'rimg--session-process #'rbridge-session-process)
(defalias 'rimg--session-capabilities #'rbridge-session-capabilities)
(defalias 'rimg--session-last-used #'rbridge-session-last-used)
(gv-define-setter rimg--session-process (value session)
  `(setf (rbridge-session-process ,session) ,value))

(cl-defstruct (rimg--gallery-job (:constructor rimg--gallery-job-create))
  index
  marker
  original
  state)

(defvar rimg--sessions (make-hash-table :test #'equal)
  "Map remote identities to active or reusable rimg sessions.")

(defvar-local rimg--gallery-session nil)
(defvar-local rimg--gallery-dired-buffer nil)
(defvar-local rimg--gallery-files nil)
(defvar-local rimg--gallery-page-index 0)
(defvar-local rimg--gallery-generation 0)
(defvar-local rimg--gallery-pending 0)
(defvar-local rimg--gallery-jobs nil)
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

(defun rimg--session-transition (session next-state)
  "Move SESSION to NEXT-STATE if the transition is valid."
  (rbridge-session-transition session next-state))

(defun rimg--attach-process-sentinel (session process)
  "Attach SSH PROCESS lifecycle handling to SESSION."
  (rbridge-attach-process-sentinel session process))

(defun rimg--remote-from-path (path)
  "Parse supported remote PATH into an `rimg--remote'."
  (rbridge-remote-from-path path "rimg"))

(defun rimg--bridge-service ()
  "Return the rbridge service definition for rimgd."
  (rbridge-service-create
   :name "rimg"
   :binary-name "rimgd"
   :version rimg-server-version
   :protocol rimg-protocol-version
   :binary-directory rimg-server-binary-directory
   :remote-install-directory "~/.cache/rimg/bin"
   :serve-arguments-function
   (lambda (session)
     (let ((cache-dir
            (rbridge-remote-expanded-localname
             (rbridge-session-remote session)
             rimg-server-cache-directory)))
       (setf (rbridge-session-cache-dir session) cache-dir)
       (list "--cache-dir" cache-dir)))))

(defun rimg--server-artifact-name (operating-system architecture)
  "Return the rimgd artifact for OPERATING-SYSTEM and ARCHITECTURE."
  (rbridge-artifact-name
   (rimg--bridge-service) operating-system architecture))

(defun rimg--server-install-localname ()
  "Return the versioned remote local name used to install rimgd."
  (rbridge-server-install-localname (rimg--bridge-service)))

(defun rimg--ssh-command (remote local-port socket-path binary-path cache-dir)
  "Build the SSH command for REMOTE and its rimgd session.
LOCAL-PORT is bound on loopback and forwarded to remote SOCKET-PATH.  The
remote command starts BINARY-PATH with CACHE-DIR."
  (let ((rbridge-ssh-program rimg-ssh-program))
    (rbridge-ssh-command
     remote (rimg--bridge-service) local-port socket-path binary-path
     (list "--cache-dir" cache-dir))))

(defun rimg--parse-health (json)
  "Parse and validate a rimgd health response from JSON."
  (condition-case error-data
      (rbridge-parse-health json (rimg--bridge-service))
    (rbridge-protocol-error
     (signal 'rimg-protocol-error (cdr error-data)))))

(defun rimg--candidate-local-port ()
  "Return a candidate local port from the dynamic/private range."
  (rbridge-candidate-local-port))

(defun rimg--remote-file-name (remote localname)
  "Build a TRAMP file name for REMOTE and LOCALNAME."
  (rbridge-remote-file-name remote localname))

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
    (rimg--gallery-line-up window)
    (rimg--gallery-request-visible window)))

(defun rimg--gallery-commit-result (buffer generation commit)
  "Run COMMIT immediately in BUFFER when GENERATION is still current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation rimg--gallery-generation)
        (let ((selected-original
               (get-text-property (point) 'original-file-name)))
          (funcall commit)
          (when selected-original
            (when-let* ((position
                         (text-property-any
                          (point-min) (point-max)
                          'original-file-name selected-original)))
              (goto-char position))))))))

(defun rimg--gallery-columns (window)
  "Return the number of rimg thumbnail columns that fit in WINDOW."
  (max 1
       (/ (window-body-width window t)
          (+ (rimg--gallery-cell-size) (frame-char-width)))))

(defun rimg--gallery-visible-range (window &optional start-position)
  "Return the prefetched slot range around WINDOW as (START . END).
START-POSITION defaults to `window-start'."
  (let ((count (length rimg--gallery-jobs)))
    (if (zerop count)
        '(0 . 0)
      (let* ((columns (rimg--gallery-columns window))
             (rows (max 1
                        (/ (+ (window-body-height window t)
                              (rimg--gallery-cell-size) -1)
                           (rimg--gallery-cell-size))))
             (position
              (text-property-not-all
               (or start-position (window-start window))
               (point-max) 'rimg-gallery-slot nil))
             (first (if position
                        (get-text-property position 'rimg-gallery-slot)
                      (1- count)))
             (row-start (* (/ first columns) columns))
             (prefetch (* columns (max 0 rimg-gallery-prefetch-rows))))
        (cons (max 0 (- row-start prefetch))
              (min count (+ row-start (* columns rows) prefetch)))))))

(defun rimg--gallery-request-range (buffer generation start end)
  "Request cold gallery jobs in BUFFER from START up to END for GENERATION."
  (let (jobs session dired-buffer)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (= generation rimg--gallery-generation)
          (setq session rimg--gallery-session
                dired-buffer rimg--gallery-dired-buffer)
          (cl-loop for index from start below end
                   for job = (aref rimg--gallery-jobs index)
                   when (eq (rimg--gallery-job-state job) 'cold)
                   do (setf (rimg--gallery-job-state job) 'requested)
                   and do (setq rimg--gallery-pending
                                (1+ rimg--gallery-pending))
                   and do (push job jobs)))))
    (setq jobs (nreverse jobs))
    (dolist (job jobs)
      (let ((marker (rimg--gallery-job-marker job))
            (original (rimg--gallery-job-original job)))
        (rimg--request-thumbnail
         session original
         (lambda (thumbnail)
           (rimg--gallery-commit-result
            buffer generation
            (lambda ()
              (rimg--gallery-thumbnail-ready
               buffer marker generation original dired-buffer thumbnail))))
         (lambda (error-data)
           (rimg--gallery-commit-result
            buffer generation
            (lambda ()
              (rimg--gallery-thumbnail-error
               buffer marker generation error-data)))))))
    (when (and jobs
               (or (null (rimg--session-capabilities session))
                   (alist-get 'prepare (rimg--session-capabilities session))))
      (rimg--request-prepare
       session (mapcar #'rimg--gallery-job-original jobs)))))

(defun rimg--gallery-request-visible (window)
  "Request cold thumbnail slots around the visible part of WINDOW."
  (when (and rimg-thumbnail-mode
             (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             rimg--gallery-jobs)
    (pcase-let ((`(,start . ,end) (rimg--gallery-visible-range window)))
      (rimg--gallery-request-range
       (current-buffer) rimg--gallery-generation start end))))

(defun rimg--gallery-window-scrolled (window _start)
  "Load cold gallery slots after WINDOW scrolls."
  (when rimg-thumbnail-mode
    (rimg--gallery-request-visible window)))

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
            (let ((slot (get-text-property marker 'rimg-gallery-slot)))
              (delete-char 1)
              (let ((begin (point)))
                (image-dired-insert-thumbnail thumbnail original dired-buffer)
                (add-text-properties
                 begin (point) (list 'rimg-gallery-slot slot))))))
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
  (let (jobs generation page-files)
    (with-current-buffer buffer
      (setq rimg--gallery-generation (1+ rimg--gallery-generation)
            generation rimg--gallery-generation)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq page-files (rimg--gallery-page-files))
        (setq-local image-dired-thumbnail-storage 'image-dired)
        (setq-local image-dired-thumb-size rimg-thumbnail-size)
        (setq-local image-dired-line-up-method 'dynamic)
        (setq image-dired--number-of-thumbnails (length page-files)
              rimg--gallery-jobs nil
              rimg--gallery-pending 0
              rimg--gallery-layout-width nil)
        (cl-loop for original in page-files
                 for index from 0
                 do
                 (insert (rimg--gallery-placeholder
                          index original rimg--gallery-dired-buffer)
                         " ")
                 (push (list index original) jobs)))
      (setq jobs (nreverse jobs)))
    (pop-to-buffer buffer)
    (when-let* ((window (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (rimg--gallery-line-up window)))
    ;; Create markers only after the initial layout.  Image-Dired deletes and
    ;; reinserts separators while lining up, which can move earlier markers.
    (with-current-buffer buffer
      (setq rimg--gallery-jobs
            (vconcat
             (mapcar
              (lambda (job)
                (pcase-let ((`(,index ,original) job))
                  (let ((position
                         (text-property-any
                          (point-min) (point-max) 'rimg-gallery-slot index)))
                    (unless position
                      (error "rimg: gallery slot %d disappeared during layout"
                             index))
                    (rimg--gallery-job-create
                     :index index
                     :marker (copy-marker position)
                     :original original
                     :state 'cold))))
              jobs)))
      (goto-char (point-min)))
    (if-let* ((window (get-buffer-window buffer t)))
        (progn
          (set-window-start window (with-current-buffer buffer (point-min)) t)
          (with-current-buffer buffer
            (rimg--gallery-request-visible window)))
      ;; A gallery is normally visible after `pop-to-buffer'.  Keep a bounded
      ;; fallback for noninteractive callers that replace that function.
      (rimg--gallery-request-range
       buffer generation 0 (min (length jobs) rimg-http-parallelism)))
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
                #'rimg--gallery-window-size-changed nil t)
      (add-hook 'window-scroll-functions
                #'rimg--gallery-window-scrolled nil t))
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
  (rbridge-remote-expanded-localname remote localname))

(defun rimg--remote-process-output (remote program &rest arguments)
  "Run PROGRAM with ARGUMENTS on REMOTE and return trimmed stdout."
  (apply #'rbridge-remote-process-output remote program arguments))

(defun rimg--detect-server-artifact (remote)
  "Detect REMOTE platform and return its local rimgd artifact name."
  (rbridge-detect-server-artifact remote (rimg--bridge-service)))

(defun rimg--local-server-artifact (remote)
  "Return the local rimgd artifact path suitable for REMOTE."
  (rbridge-local-server-artifact remote (rimg--bridge-service)))

(defun rimg--installed-server-current-p (remote binary-localname)
  "Return non-nil when REMOTE BINARY-LOCALNAME matches this client."
  (rbridge-installed-server-current-p
   remote (rimg--bridge-service) binary-localname))

(defun rimg--install-server (remote local-artifact binary-localname)
  "Atomically install LOCAL-ARTIFACT on REMOTE as BINARY-LOCALNAME."
  (let ((rbridge-bootstrap-enabled rimg-bootstrap-enabled))
    (rbridge-install-server
     remote (rimg--bridge-service) local-artifact binary-localname)))

(defun rimg--ensure-server (remote)
  "Return the absolute remote-local rimgd path for REMOTE, installing if needed."
  (let ((rbridge-bootstrap-enabled rimg-bootstrap-enabled))
    (rbridge-ensure-server remote (rimg--bridge-service))))

(defun rimg--session-id ()
  "Return a short unique identifier suitable for a Unix socket name."
  (rbridge-session-id))

(defun rimg--remote-runtime-directory (remote)
  "Create and return REMOTE's private rimg runtime directory."
  (rbridge-remote-runtime-directory remote (rimg--bridge-service)))

(defun rimg--ssh-log-buffer (remote)
  "Return the SSH log buffer for REMOTE."
  (rbridge-ssh-log-buffer remote (rimg--bridge-service)))

(defun rimg--start-ssh-process (session)
  "Start the SSH process for SESSION and return it."
  (let ((rbridge-ssh-program rimg-ssh-program))
    (unless (rbridge-session-service session)
      (setf (rbridge-session-service session) (rimg--bridge-service)))
    (rbridge-start-ssh-process session)))

(defun rimg--request-health (session)
  "Request and validate health for SESSION synchronously."
  (unless (rbridge-session-service session)
    (setf (rbridge-session-service session) (rimg--bridge-service)))
  (condition-case error-data
      (rbridge-request-health session)
    (rbridge-protocol-error
     (signal 'rimg-protocol-error (cdr error-data)))))

(defun rimg--wait-for-health (session)
  "Poll SESSION health until ready or `rimg-connect-timeout' expires."
  (let ((rbridge-connect-timeout rimg-connect-timeout))
    (rbridge-wait-for-health session)))

(defun rimg--session-live-ready-p (session)
  "Return non-nil when SESSION can be reused."
  (rbridge-session-live-ready-p session))

(defun rimg--connect-remote (remote)
  "Bootstrap and connect a reusable rimg SESSION for REMOTE."
  (let ((rbridge-ssh-program rimg-ssh-program)
        (rbridge-bootstrap-enabled rimg-bootstrap-enabled)
        (rbridge-connect-timeout rimg-connect-timeout)
        (rbridge-ssh-port-attempts rimg-ssh-port-attempts))
    (rbridge-connect remote (rimg--bridge-service) rimg--sessions)))

(defun rimg--disconnect-session (session)
  "Stop SESSION and mark it dead."
  (rbridge-disconnect-session session))

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
