;;; rvid.el --- Play remote TRAMP media through a local player -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: multimedia, files

;;; Commentary:

;; rvid accepts a TRAMP file path from any caller.  A per-session
;; rvidd process exposes capability-scoped, read-only HTTP byte ranges through
;; an SSH tunnel.  The bytes go directly from OpenSSH to mpv or WebKit and do
;; not pass through an Emacs Lisp buffer.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'rbridge)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)

(defvar url-http-response-status)
(declare-function dired-get-file-for-visit "dired")
(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function set-xwidget-query-on-exit-flag "xwidget.c" (xwidget flag))

(defgroup rvid nil
  "Play remote media addressed by a TRAMP file name."
  :group 'multimedia)

(defconst rvid-server-version "0.1.0")
(defconst rvid-protocol-version 1)

(defconst rvid--package-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Root of the rvid source or installed package tree.")

(defcustom rvid-server-binary-directory
  (expand-file-name "dist" rvid--package-root)
  "Local directory containing platform-specific rvidd binaries."
  :type 'directory)

(defcustom rvid-ssh-program "ssh"
  "OpenSSH client used for rvid data-plane sessions."
  :type 'string)

(defcustom rvid-bootstrap-enabled t
  "Whether rvid may install its versioned remote binary through TRAMP."
  :type 'boolean)

(defcustom rvid-connect-timeout 5.0
  "Seconds to wait for rvidd health after SSH starts."
  :type 'number)

(defcustom rvid-ssh-port-attempts 10
  "Maximum local port attempts for an rvid SSH session."
  :type 'integer)

(defcustom rvid-token-idle-ttl "24h"
  "Idle lifetime passed to rvidd for registered media URLs."
  :type 'string)

(defcustom rvid-max-open-media 256
  "Maximum media capabilities retained by one rvidd session."
  :type 'integer)

(defcustom rvid-player-backend 'auto
  "Backend used by `rvid-play'.
When set to `auto', prefer local mpv and fall back to an embedded WebKit
xwidget."
  :type '(choice (const :tag "Prefer mpv, then WebKit" auto)
                 (const :tag "External mpv" mpv)
                 (const :tag "Embedded WebKit" xwidget)))

(defcustom rvid-mpv-program "mpv"
  "Local mpv executable used by the mpv backend."
  :type 'string)

(defcustom rvid-mpv-arguments
  '("--force-window=yes"
    "--cache=yes"
    "--cache-pause=yes"
    "--terminal=no")
  "Additional arguments passed to the local mpv process."
  :type '(repeat string))

(defcustom rvid-registration-timeout 5.0
  "Seconds to wait when registering or revoking a media capability."
  :type 'number)

(cl-defstruct (rvid-registration (:constructor rvid-registration-create))
  id
  name
  size
  mtime-ns
  etag
  url-path
  content-type)

(cl-defstruct (rvid-playback (:constructor rvid-playback-create))
  backend
  registration
  session
  process
  buffer
  ipc-socket
  runtime-directory
  cleaned)

(defvar rvid--sessions (make-hash-table :test #'equal)
  "Map remote identities to active or reusable rvid sessions.")

(defvar rvid--current-playback nil
  "The current `rvid-playback', if any.")

(defvar-local rvid--xwidget-playback nil)

(defvar rvid--make-process-function #'make-process
  "Process constructor used internally, replaceable by tests.")

(defvar rvid--file-directory-p-function #'file-directory-p
  "Directory predicate used internally, replaceable by tests.")

(defvar rvid--file-regular-p-function #'file-regular-p
  "Regular-file predicate used internally, replaceable by tests.")

(defun rvid--random-token ()
  "Return an unpredictable session token encoded as hexadecimal."
  (unless (executable-find "dd")
    (error "rvid: cannot generate a session token because dd is unavailable"))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (unless (zerop
               (call-process
                "dd" nil (list t nil) nil
                "if=/dev/urandom" "bs=32" "count=1"))
        (error "rvid: failed to read operating-system entropy")))
    (unless (= (buffer-size) 32)
      (error "rvid: operating-system entropy source returned %d bytes"
             (buffer-size)))
    (secure-hash 'sha256 (buffer-string))))

(defun rvid--bridge-service ()
  "Return the rbridge service definition for rvidd."
  (rbridge-service-create
   :name "rvid"
   :binary-name "rvidd"
   :version rvid-server-version
   :protocol rvid-protocol-version
   :binary-directory rvid-server-binary-directory
   :remote-install-directory "~/.cache/rvid/bin"
   :ssh-options '("-o" "Compression=no")
   :sensitive-options '("--auth-token")
   :serve-arguments-function
   (lambda (session)
     (let* ((metadata (rbridge-session-metadata session))
            (token (or (plist-get metadata :auth-token)
                       (rvid--random-token))))
       (setf (rbridge-session-metadata session)
             (plist-put metadata :auth-token token))
       (list "--auth-token" token
             "--token-idle-ttl" rvid-token-idle-ttl
             "--max-open" (number-to-string rvid-max-open-media))))))

(defun rvid--remote-from-path (path)
  "Return the rbridge remote represented by TRAMP PATH."
  (rbridge-remote-from-path path "rvid"))

(defun rvid--connect-remote (remote)
  "Bootstrap and connect a reusable rvid session for REMOTE."
  (let ((rbridge-ssh-program rvid-ssh-program)
        (rbridge-bootstrap-enabled rvid-bootstrap-enabled)
        (rbridge-connect-timeout rvid-connect-timeout)
        (rbridge-ssh-port-attempts rvid-ssh-port-attempts))
    (rbridge-connect remote (rvid--bridge-service) rvid--sessions)))

(defun rvid-connect (&optional path)
  "Connect rvid for remote PATH or `default-directory'."
  (interactive)
  (let* ((remote (rvid--remote-from-path (or path default-directory)))
         (session (rvid--connect-remote remote)))
    (message "rvid: connected to %s on local port %d"
             (rbridge-remote-host remote)
             (rbridge-session-local-port session))
    session))

(defun rvid-disconnect (&optional path)
  "Stop playback and disconnect rvid for remote PATH."
  (interactive)
  (let* ((remote (rvid--remote-from-path (or path default-directory)))
         (session (gethash (rbridge-remote-identity remote) rvid--sessions)))
    (when (and rvid--current-playback
               (eq session (rvid-playback-session rvid--current-playback)))
      (rvid-stop))
    (when session
      (rbridge-disconnect-session session)
      (message "rvid: disconnected from %s" (rbridge-remote-host remote)))))

(defun rvid-reconnect (&optional path)
  "Reconnect rvid for remote PATH."
  (interactive)
  (rvid-disconnect path)
  (rvid-connect path))

(defun rvid--session-auth-token (session)
  "Return SESSION's private media-registration token."
  (or (plist-get (rbridge-session-metadata session) :auth-token)
      (error "rvid: session has no registration token")))

(defun rvid--response-body-start ()
  "Return the start position of the current HTTP response body."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "rvid: malformed HTTP response"))
  (point))

(defun rvid--response-json (buffer expected-status operation)
  "Decode BUFFER JSON after EXPECTED-STATUS for OPERATION."
  (unwind-protect
      (with-current-buffer buffer
        (let ((body-start (rvid--response-body-start)))
          (unless (equal url-http-response-status expected-status)
            (let* ((body (buffer-substring-no-properties
                          body-start (point-max)))
                   (decoded (ignore-errors
                              (json-parse-string body :object-type 'alist)))
                   (protocol-error (alist-get 'error decoded))
                   (message-text (or (alist-get 'message protocol-error)
                                     body)))
              (error "rvid: %s returned HTTP %s: %s"
                     operation url-http-response-status message-text)))
          (json-parse-string
           (buffer-substring-no-properties body-start (point-max))
           :object-type 'alist :array-type 'list)))
    (kill-buffer buffer)))

(defun rvid--register-media (session remote-localname)
  "Register REMOTE-LOCALNAME with SESSION and return a capability."
  (let* ((url-proxy-services nil)
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Authorization" . ,(concat
                                   "Bearer "
                                   (rvid--session-auth-token session)))))
         (url-request-data
          (json-serialize (list (cons 'path remote-localname))))
         (buffer
          (url-retrieve-synchronously
           (rbridge-session-url session "/v1/media/open")
           t t rvid-registration-timeout)))
    (unless buffer
      (error "rvid: media registration timed out"))
    (let ((result (rvid--response-json buffer 201 "media registration")))
      (rvid-registration-create
       :id (alist-get 'id result)
       :name (alist-get 'name result)
       :size (alist-get 'size result)
       :mtime-ns (alist-get 'mtime_ns result)
       :etag (alist-get 'etag result)
       :url-path (alist-get 'url_path result)
       :content-type (alist-get 'content_type result)))))

(defun rvid--media-url (session registration)
  "Return the local playback URL for SESSION REGISTRATION."
  (rbridge-session-url session (rvid-registration-url-path registration)))

(defun rvid--player-url (session registration)
  "Return the embedded WebKit player URL for SESSION REGISTRATION."
  (rbridge-session-url
   session (format "/v1/player/%s" (rvid-registration-id registration))))

(defun rvid--revoke-registration (session registration)
  "Best-effort revoke REGISTRATION on SESSION."
  (when (and session registration
             (rbridge-session-live-ready-p session))
    (let* ((url-proxy-services nil)
           (url-request-method "DELETE")
           (url-request-extra-headers
            `(("Authorization" . ,(concat
                                     "Bearer "
                                     (rvid--session-auth-token session)))))
           (buffer
            (ignore-errors
              (url-retrieve-synchronously
               (rbridge-session-url
                session
                (format "/v1/media/%s"
                        (rvid-registration-id registration)))
               t t rvid-registration-timeout))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun rvid--mpv-available-p ()
  "Return non-nil when the configured local mpv executable is available."
  (executable-find rvid-mpv-program))

(defun rvid--xwidget-available-p ()
  "Return non-nil when this Emacs can display a WebKit xwidget."
  (and (display-graphic-p)
       (featurep 'xwidget-internal)
       (require 'xwidget nil t)))

(defun rvid--validate-backend (backend)
  "Signal a user error unless BACKEND is available."
  (pcase backend
    ('mpv
     (unless (rvid--mpv-available-p)
       (user-error "rvid: mpv is not installed or `rvid-mpv-program' is incorrect")))
    ('xwidget
     (unless (rvid--xwidget-available-p)
       (user-error "rvid: this graphical Emacs does not support WebKit xwidgets")))
    (_ (user-error "rvid: unsupported player backend: %s" backend))))

(defun rvid--resolve-backend (backend)
  "Resolve configured BACKEND to an available concrete player backend."
  (if (eq backend 'auto)
      (cond
       ((rvid--mpv-available-p) 'mpv)
       ((rvid--xwidget-available-p) 'xwidget)
       (t
        (user-error
         "rvid: neither mpv nor graphical WebKit xwidgets are available")))
    (rvid--validate-backend backend)
    backend))

(defun rvid--validate-file (file)
  "Signal a clear user error unless FILE is a regular remote file."
  (unless (and (stringp file) (tramp-tramp-file-p file))
    (user-error "rvid: selected file is not remote"))
  (cond
   ((funcall rvid--file-directory-p-function file)
    (user-error "rvid: selected path is a directory; select a video file"))
   ((not (funcall rvid--file-regular-p-function file))
    (user-error "rvid: selected path is not a regular file"))))

(defun rvid--start-mpv (session registration)
  "Start local mpv for SESSION REGISTRATION and return playback state."
  (let* ((runtime-directory (make-temp-file "rvid-mpv-" t))
         (ipc-socket (expand-file-name "ipc.sock" runtime-directory))
         (log-buffer (get-buffer-create "*rvid-mpv*"))
         (url (rvid--media-url session registration))
         (command
          (append
           (list rvid-mpv-program)
           rvid-mpv-arguments
           (list (format "--input-ipc-server=%s" ipc-socket)
                 (format "--title=%s" (rvid-registration-name registration))
                 "--" url)))
         (playback
          (rvid-playback-create
           :backend 'mpv
           :registration registration
           :session session
           :ipc-socket ipc-socket
           :runtime-directory runtime-directory))
         process)
    (set-file-modes runtime-directory #o700)
    (condition-case error-data
        (setq process
              (funcall rvid--make-process-function
                       :name "rvid-mpv"
                       :buffer log-buffer
                       :command command
                       :connection-type 'pipe
                       :noquery t))
      (error
       (delete-directory runtime-directory t)
       (signal (car error-data) (cdr error-data))))
    (setf (rvid-playback-process playback) process)
    (set-process-sentinel
     process
     (lambda (finished-process _event)
       (when (memq (process-status finished-process) '(exit signal failed))
         (run-at-time 0 nil #'rvid--cleanup-playback playback))))
    playback))

(defun rvid--start-xwidget (session registration)
  "Start embedded WebKit playback for SESSION REGISTRATION."
  (let* ((playback
          (rvid-playback-create
           :backend 'xwidget
           :registration registration
           :session session))
         (url (rvid--player-url session registration)))
    (xwidget-webkit-browse-url url t)
    (let ((buffer (current-buffer)))
      ;; This buffer is owned by rvid and its kill hook revokes the media
      ;; capability.  Do not let the global xwidget query hook block
      ;; `rvid-stop' or switching to the next video with a minibuffer prompt.
      (dolist (xwidget (get-buffer-xwidgets buffer))
        (set-xwidget-query-on-exit-flag xwidget nil))
      (setf (rvid-playback-buffer playback) buffer)
      (with-current-buffer buffer
        (setq-local rvid--xwidget-playback playback)
        (add-hook 'kill-buffer-hook #'rvid--xwidget-buffer-killed nil t)))
    playback))

(defun rvid--xwidget-buffer-killed ()
  "Clean up the playback associated with the current xwidget buffer."
  (when rvid--xwidget-playback
    (rvid--cleanup-playback rvid--xwidget-playback)))

(defun rvid--cleanup-playback (playback)
  "Release local and remote resources owned by PLAYBACK."
  (unless (rvid-playback-cleaned playback)
    (setf (rvid-playback-cleaned playback) t)
    (rvid--revoke-registration
     (rvid-playback-session playback)
     (rvid-playback-registration playback))
    (when-let* ((directory (rvid-playback-runtime-directory playback)))
      (when (file-directory-p directory)
        (delete-directory directory t)))
    (when (eq rvid--current-playback playback)
      (setq rvid--current-playback nil))))

(defun rvid--file-at-point ()
  "Return a contextual file or prompt for a remote file.
Callers that already have a path pass it directly to `rvid-play'; this helper
is only used by an interactive `M-x rvid-play'."
  (cond
   ((derived-mode-p 'dired-mode) (dired-get-file-for-visit))
   ((and buffer-file-name (tramp-tramp-file-p buffer-file-name))
    buffer-file-name)
   (t (read-file-name "Remote media file: " default-directory nil t))))

;;;###autoload
(defun rvid-play (file &optional backend)
  "Play remote TRAMP FILE using BACKEND or `rvid-player-backend'."
  (interactive (list (rvid--file-at-point)))
  (rvid--validate-file file)
  (let ((backend (rvid--resolve-backend
                  (or backend rvid-player-backend))))
    (when rvid--current-playback
      (rvid-stop))
    (let* ((remote (rvid--remote-from-path file))
           (remote-localname
            (rbridge-remote-expanded-localname
             remote (rbridge-remote-localname remote)))
           (session (rvid--connect-remote remote))
           (registration (rvid--register-media session remote-localname))
           (playback
            (condition-case error-data
                (pcase backend
                  ('mpv (rvid--start-mpv session registration))
                  ('xwidget (rvid--start-xwidget session registration)))
              (error
               (rvid--revoke-registration session registration)
               (signal (car error-data) (cdr error-data))))))
      (setq rvid--current-playback playback)
      (message "rvid: playing %s via %s"
               (rvid-registration-name registration) backend)
      playback)))

;;;###autoload
(defun rvid-play-in-emacs (file)
  "Play remote FILE in an embedded WebKit xwidget."
  (interactive (list (rvid--file-at-point)))
  (rvid-play file 'xwidget))

(defun rvid-stop ()
  "Stop the current rvid playback and revoke its media URL."
  (interactive)
  (when-let* ((playback rvid--current-playback))
    (setf (rvid-playback-cleaned playback) t)
    (when-let* ((process (rvid-playback-process playback)))
      (when (process-live-p process)
        (delete-process process)))
    (when-let* ((buffer (rvid-playback-buffer playback)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    ;; The cleaned flag prevents buffer/process sentinels from racing this
    ;; explicit cleanup, so release the resources here exactly once.
    (setf (rvid-playback-cleaned playback) nil)
    (rvid--cleanup-playback playback)
    (message "rvid: playback stopped")))

(defun rvid--mpv-command (command)
  "Send one JSON IPC COMMAND to the current mpv process."
  (let* ((playback rvid--current-playback)
         (socket (and playback (rvid-playback-ipc-socket playback))))
    (unless (and playback (eq (rvid-playback-backend playback) 'mpv)
                 socket (file-exists-p socket))
      (user-error "rvid: mpv IPC is not ready"))
    (let ((connection
           (make-network-process
            :name "rvid-mpv-ipc"
            :family 'local
            :service socket
            :coding 'utf-8-unix
            :noquery t)))
      (process-send-string
       connection
       (concat (json-serialize (list (cons 'command command))) "\n"))
      (process-send-eof connection)
      (accept-process-output connection 0.05)
      (when (process-live-p connection)
        (delete-process connection)))))

(defun rvid-toggle-pause ()
  "Toggle pause in the current mpv playback."
  (interactive)
  (rvid--mpv-command ["cycle" "pause"]))

(defun rvid-seek-forward (&optional seconds)
  "Seek forward SECONDS in the current mpv playback."
  (interactive
   (list (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           10)))
  (rvid--mpv-command
   (vector "seek" (or seconds 10) "relative+keyframes")))

(defun rvid-seek-backward (&optional seconds)
  "Seek backward SECONDS in the current mpv playback."
  (interactive
   (list (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           10)))
  (rvid-seek-forward (- (or seconds 10))))

(provide 'rvid)

;;; rvid.el ends here
