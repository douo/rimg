;;; rimg.el --- Remote image data plane for Image-Dired -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: multimedia, files

;;; Commentary:

;; rimg keeps Dired and TRAMP as the remote file control plane while obtaining
;; thumbnails and previews from a per-session rimgd process over an SSH tunnel.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)

(defvar url-http-response-status)

(defgroup rimg nil
  "Remote image acceleration for TRAMP and Image-Dired."
  :group 'multimedia)

(defconst rimg-server-version "0.1.0")
(defconst rimg-protocol-version 1)

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

(defcustom rimg-server-cache-directory "~/.cache/rimg/thumbs"
  "Persistent cache directory on each remote rimgd host."
  :type 'string)

(defcustom rimg-connect-timeout 5.0
  "Seconds to wait for rimgd health after SSH starts."
  :type 'number)

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
    (unless (equal method "ssh")
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
                           "--cache-dir" cache-dir)
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

(provide 'rimg)

;;; rimg.el ends here
