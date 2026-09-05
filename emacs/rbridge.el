;;; rbridge.el --- Shared TRAMP SSH data-plane sessions -*- lexical-binding: t -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: files, processes

;;; Commentary:

;; rbridge contains the transport shared by rimg and rvid.  TRAMP remains the
;; bootstrap/control plane; payload traffic uses HTTP over an OpenSSH local
;; forward to a private remote Unix socket.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tramp)
(require 'url)
(require 'url-http)

(defvar url-http-response-status)

(defgroup rbridge nil
  "Shared remote data-plane sessions over OpenSSH."
  :group 'files)

(defcustom rbridge-ssh-program "ssh"
  "OpenSSH client used for data-plane sessions."
  :type 'string)

(defcustom rbridge-bootstrap-enabled t
  "Whether services may install versioned remote binaries through TRAMP."
  :type 'boolean)

(defcustom rbridge-connect-timeout 5.0
  "Seconds to wait for a service health endpoint after SSH starts."
  :type 'number)

(defcustom rbridge-ssh-port-attempts 10
  "Maximum local port attempts when starting an SSH session."
  :type 'integer)

(defconst rbridge-supported-tramp-methods '("ssh" "sshx")
  "Single-hop TRAMP methods supported by rbridge.")

(define-error 'rbridge-protocol-error "rbridge protocol error")

(cl-defstruct (rbridge-remote (:constructor rbridge-remote-create))
  method
  user
  host
  port
  localname
  prefix
  identity)

(cl-defstruct (rbridge-service (:constructor rbridge-service-create))
  name
  binary-name
  version
  protocol
  binary-directory
  remote-install-directory
  serve-arguments-function
  ssh-options
  sensitive-options)

(cl-defstruct (rbridge-session (:constructor rbridge-session-create))
  remote
  service
  state
  local-port
  socket-path
  binary-path
  cache-dir
  process
  capabilities
  last-used
  metadata)

(defconst rbridge--session-transitions
  '((absent . (bootstrapping dead))
    (bootstrapping . (starting dead))
    (starting . (waiting-health dead))
    (waiting-health . (ready dead))
    (ready . (dead))
    (dead . (bootstrapping)))
  "Allowed rbridge session state transitions.")

(defun rbridge-validate-service (service)
  "Validate SERVICE and return it."
  (unless (rbridge-service-p service)
    (error "rbridge: invalid service"))
  (dolist (value (list (rbridge-service-name service)
                       (rbridge-service-binary-name service)
                       (rbridge-service-version service)
                       (rbridge-service-binary-directory service)
                       (rbridge-service-remote-install-directory service)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "rbridge: service contains an empty required value")))
  (unless (string-match-p "\\`[a-z][a-z0-9-]*\\'"
                          (rbridge-service-name service))
    (error "rbridge: invalid service name: %s"
           (rbridge-service-name service)))
  (unless (and (integerp (rbridge-service-protocol service))
               (> (rbridge-service-protocol service) 0))
    (error "rbridge: invalid service protocol"))
  service)

(defun rbridge-session-transition (session next-state)
  "Move SESSION to NEXT-STATE if the transition is valid."
  (let* ((current (rbridge-session-state session))
         (allowed (alist-get current rbridge--session-transitions)))
    (unless (memq next-state allowed)
      (error "rbridge: invalid session transition %s -> %s"
             current next-state))
    (setf (rbridge-session-state session) next-state
          (rbridge-session-last-used session) (float-time))
    session))

(defun rbridge-attach-process-sentinel (session process)
  "Attach PROCESS lifecycle handling to SESSION."
  (set-process-query-on-exit-flag process nil)
  (set-process-sentinel
   process
   (lambda (finished-process _event)
     (when (memq (process-status finished-process) '(exit signal failed))
       (unless (eq (rbridge-session-state session) 'dead)
         (rbridge-session-transition session 'dead)))))
  process)

(defun rbridge-remote-from-path (path &optional caller)
  "Parse supported remote PATH into an `rbridge-remote'.
CALLER is used as the prefix of user-facing errors."
  (let ((caller (or caller "rbridge")))
    (unless (and (stringp path) (tramp-tramp-file-p path))
      (user-error "%s: current path is not remote" caller))
    (let* ((parsed (tramp-dissect-file-name path))
           (method (tramp-file-name-method parsed))
           (hop (tramp-file-name-hop parsed)))
      (unless (member method rbridge-supported-tramp-methods)
        (user-error "%s: remote method %s is not supported"
                    caller method))
      (when hop
        (user-error "%s: multi-hop SSH is not supported" caller))
      (let* ((user (tramp-file-name-user parsed))
             (host (tramp-file-name-host parsed))
             (port (tramp-file-name-port parsed))
             (localname (tramp-file-name-localname parsed))
             (prefix (file-remote-p path))
             (identity (mapconcat #'identity
                                  (list method (or user "") host (or port ""))
                                  "|")))
        (rbridge-remote-create
         :method method :user user :host host :port port
         :localname localname :prefix prefix :identity identity)))))

(defun rbridge-artifact-name (service operating-system architecture)
  "Return SERVICE artifact for OPERATING-SYSTEM and ARCHITECTURE."
  (rbridge-validate-service service)
  (unless (equal operating-system "Linux")
    (user-error "%s: remote operating system %s is not supported"
                (rbridge-service-name service) operating-system))
  (format "%s-linux-%s"
          (rbridge-service-binary-name service)
          (pcase architecture
            ((or "x86_64" "amd64") "amd64")
            ((or "aarch64" "arm64") "arm64")
            (_ (user-error "%s: remote architecture %s is not supported"
                           (rbridge-service-name service) architecture)))))

(defun rbridge-server-install-localname (service)
  "Return SERVICE's versioned remote install path."
  (rbridge-validate-service service)
  (format "%s/%s/%s"
          (directory-file-name
           (rbridge-service-remote-install-directory service))
          (rbridge-service-version service)
          (rbridge-service-binary-name service)))

(defun rbridge-ssh-command (remote service local-port socket-path binary-path
                                   serve-arguments)
  "Build the OpenSSH command for REMOTE SERVICE.
LOCAL-PORT is forwarded to SOCKET-PATH.  BINARY-PATH is started with
SERVE-ARGUMENTS."
  (let* ((target (if (rbridge-remote-user remote)
                     (format "%s@%s"
                             (rbridge-remote-user remote)
                             (rbridge-remote-host remote))
                   (rbridge-remote-host remote)))
         (forward (format "127.0.0.1:%d:%s" local-port socket-path))
         (remote-command
          (mapconcat #'shell-quote-argument
                     (append (list "exec" binary-path "serve"
                                   "--socket" socket-path)
                             serve-arguments
                             (list "--exit-on-stdin-eof"))
                     " ")))
    (append
     (list rbridge-ssh-program
           "-T"
           "-o" "ExitOnForwardFailure=yes"
           "-o" "ServerAliveInterval=15"
           "-o" "ServerAliveCountMax=3")
     (rbridge-service-ssh-options service)
     (list "-L" forward)
     (when (rbridge-remote-port remote)
       (list "-p" (rbridge-remote-port remote)))
     (list target remote-command))))

(defun rbridge-parse-health (json service)
  "Parse and validate JSON health response for SERVICE."
  (let ((health
         (condition-case error-data
             (json-parse-string json
                                :object-type 'alist
                                :array-type 'list
                                :null-object nil
                                :false-object nil)
           (error
            (signal 'rbridge-protocol-error
                    (list (format "invalid health JSON: %s"
                                  (error-message-string error-data))))))))
    (unless (alist-get 'ok health)
      (signal 'rbridge-protocol-error
              (list (format "%s health is not ready"
                            (rbridge-service-name service)))))
    (unless (equal (alist-get 'protocol health)
                   (rbridge-service-protocol service))
      (signal 'rbridge-protocol-error
              (list (format "protocol mismatch: server=%s client=%s"
                            (alist-get 'protocol health)
                            (rbridge-service-protocol service)))))
    health))

(defun rbridge-candidate-local-port ()
  "Return a candidate local port from the dynamic/private range."
  (+ 49152 (random (- 65536 49152))))

(defun rbridge-remote-file-name (remote localname)
  "Build a TRAMP file name for REMOTE and LOCALNAME."
  (concat (rbridge-remote-prefix remote) localname))

(defun rbridge-remote-expanded-localname (remote localname)
  "Expand remote LOCALNAME and return its absolute remote-local path."
  (file-remote-p
   (expand-file-name (rbridge-remote-file-name remote localname))
   'localname))

(defun rbridge-remote-process-output (remote program &rest arguments)
  "Run PROGRAM with ARGUMENTS on REMOTE and return trimmed stdout."
  (with-temp-buffer
    (let* ((default-directory (rbridge-remote-file-name remote "~/"))
           (status (apply #'process-file program nil (current-buffer) nil
                          arguments))
           (output (string-trim (buffer-string))))
      (unless (and (integerp status) (zerop status))
        (error "rbridge: remote command failed (%s): %s" status output))
      output)))

(defun rbridge-detect-server-artifact (remote service)
  "Detect REMOTE platform and return SERVICE's local artifact name."
  (rbridge-artifact-name
   service
   (rbridge-remote-process-output remote "uname" "-s")
   (rbridge-remote-process-output remote "uname" "-m")))

(defun rbridge-local-server-artifact (remote service)
  "Return the local SERVICE artifact suitable for REMOTE."
  (let ((artifact
         (expand-file-name
          (rbridge-detect-server-artifact remote service)
          (rbridge-service-binary-directory service))))
    (unless (file-readable-p artifact)
      (error "%s: server artifact is missing: %s (run `make dist')"
             (rbridge-service-name service) artifact))
    artifact))

(defun rbridge-installed-server-current-p (remote service binary-localname)
  "Return non-nil when REMOTE BINARY-LOCALNAME matches SERVICE."
  (let ((remote-file (rbridge-remote-file-name remote binary-localname)))
    (and
     (file-executable-p remote-file)
     (condition-case nil
         (let ((version
                (json-parse-string
                 (rbridge-remote-process-output
                  remote binary-localname "version" "--json")
                 :object-type 'alist)))
           (and (equal (alist-get 'version version)
                       (rbridge-service-version service))
                (equal (alist-get 'protocol version)
                       (rbridge-service-protocol service))))
       (error nil)))))

(defun rbridge-session-id ()
  "Return a short unique identifier suitable for a Unix socket name."
  (substring
   (secure-hash 'sha256
                (format "%s:%s:%s:%s"
                        (emacs-pid) (float-time) (random) (recent-keys)))
   0 12))

(defun rbridge-install-server (remote service local-artifact binary-localname)
  "Atomically install LOCAL-ARTIFACT on REMOTE as BINARY-LOCALNAME."
  (unless rbridge-bootstrap-enabled
    (error "%s: remote server is missing or incompatible and bootstrap is disabled"
           (rbridge-service-name service)))
  (let* ((remote-file (rbridge-remote-file-name remote binary-localname))
         (remote-directory (file-name-directory remote-file))
         (temporary (format "%s.tmp.%s" remote-file (rbridge-session-id))))
    (make-directory remote-directory t)
    (unwind-protect
        (progn
          (copy-file local-artifact temporary t)
          (set-file-modes temporary #o755)
          (rename-file temporary remote-file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun rbridge-ensure-server (remote service)
  "Return absolute remote-local SERVICE path, installing when needed."
  (let ((binary-localname
         (rbridge-remote-expanded-localname
          remote (rbridge-server-install-localname service))))
    (unless (rbridge-installed-server-current-p
             remote service binary-localname)
      (rbridge-install-server
       remote service
       (rbridge-local-server-artifact remote service)
       binary-localname)
      (unless (rbridge-installed-server-current-p
               remote service binary-localname)
        (error "%s: installed server failed version verification"
               (rbridge-service-name service))))
    binary-localname))

(defun rbridge-remote-runtime-directory (remote service)
  "Create and return REMOTE's private runtime directory for SERVICE."
  (let* ((name (rbridge-service-name (rbridge-validate-service service)))
         (script
          (format
           (concat
            "set -eu; uid=$(id -u); name=%s; "
            "if [ -n \"${XDG_RUNTIME_DIR:-}\" ] && [ -d \"$XDG_RUNTIME_DIR\" ]; then "
            "base=\"${XDG_RUNTIME_DIR%%/}/$name\"; "
            "elif [ -n \"${TMPDIR:-}\" ]; then base=\"${TMPDIR%%/}/$name-$uid\"; "
            "else base=\"/tmp/$name-$uid\"; fi; "
            "case \"$base\" in /*) ;; *) base=\"/tmp/$name-$uid\" ;; esac; "
            "if [ ${#base} -gt 70 ]; then base=\"/tmp/$name-$uid\"; fi; "
            "umask 077; mkdir -p -- \"$base\"; chmod 700 -- \"$base\"; printf %%s \"$base\"")
           (shell-quote-argument name))))
    (rbridge-remote-process-output remote "sh" "-c" script)))

(defun rbridge-ssh-log-buffer (remote service)
  "Return the SSH log buffer for REMOTE SERVICE."
  (get-buffer-create
   (format "*%s-ssh:%s*"
           (rbridge-service-name service)
           (rbridge-remote-host remote))))

(defun rbridge-start-ssh-process (session)
  "Start the SSH process for SESSION and return it."
  (let* ((remote (rbridge-session-remote session))
         (service (rbridge-session-service session))
         (arguments-function
          (rbridge-service-serve-arguments-function service))
         (serve-arguments
          (if arguments-function
              (funcall arguments-function session)
            nil))
         (command
          (rbridge-ssh-command
           remote service
           (rbridge-session-local-port session)
           (rbridge-session-socket-path session)
           (rbridge-session-binary-path session)
           serve-arguments))
         (log-command
          (rbridge-ssh-command
           remote service
           (rbridge-session-local-port session)
           (rbridge-session-socket-path session)
           (rbridge-session-binary-path session)
           (rbridge--redact-arguments
            serve-arguments (rbridge-service-sensitive-options service))))
         (log-buffer (rbridge-ssh-log-buffer remote service))
         (process-connection-type nil)
         process)
    (with-current-buffer log-buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n[%s] %S\n"
                        (current-time-string) log-command))))
    (setq process
          (apply #'start-process
                 (format "%s-ssh:%s:%s"
                         (rbridge-service-name service)
                         (rbridge-remote-host remote)
                         (rbridge-session-local-port session))
                 log-buffer
                 (car command)
                 (cdr command)))
    (setf (rbridge-session-process session) process)
    (rbridge-attach-process-sentinel session process)
    process))

(defun rbridge--redact-arguments (arguments sensitive-options)
  "Redact values following SENSITIVE-OPTIONS in ARGUMENTS."
  (let ((remaining arguments)
        result)
    (while remaining
      (let ((argument (pop remaining)))
        (push argument result)
        (when (and (member argument sensitive-options) remaining)
          (pop remaining)
          (push "<redacted>" result))))
    (nreverse result)))

(defun rbridge-request-health (session)
  "Request and validate health for SESSION synchronously."
  (let* ((url-proxy-services nil)
         (url-request-method "GET")
         (url (format "http://127.0.0.1:%d/v1/health"
                      (rbridge-session-local-port session)))
         (buffer (url-retrieve-synchronously url t t 0.3)))
    (unless buffer
      (error "%s: health request timed out"
             (rbridge-service-name (rbridge-session-service session))))
    (unwind-protect
        (with-current-buffer buffer
          (unless (equal url-http-response-status 200)
            (error "%s: health returned HTTP %s"
                   (rbridge-service-name (rbridge-session-service session))
                   url-http-response-status))
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "%s: malformed health response"
                   (rbridge-service-name (rbridge-session-service session))))
          (rbridge-parse-health
           (buffer-substring-no-properties (point) (point-max))
           (rbridge-session-service session)))
      (kill-buffer buffer))))

(defun rbridge-wait-for-health (session)
  "Poll SESSION health until ready or timeout expires."
  (let ((deadline (+ (float-time) rbridge-connect-timeout))
        (delay 0.05)
        (last-error nil)
        health)
    (while (and (not health) (< (float-time) deadline))
      (unless (process-live-p (rbridge-session-process session))
        (error "%s: SSH exited before server became ready; see %s"
               (rbridge-service-name (rbridge-session-service session))
               (buffer-name
                (rbridge-ssh-log-buffer
                 (rbridge-session-remote session)
                 (rbridge-session-service session)))))
      (condition-case error-data
          (setq health (rbridge-request-health session))
        (error (setq last-error error-data)))
      (unless health
        (accept-process-output (rbridge-session-process session) delay)
        (setq delay (min 0.4 (* delay 2)))))
    (or health
        (if last-error
            (signal (car last-error) (cdr last-error))
          (error "%s: health timeout"
                 (rbridge-service-name
                  (rbridge-session-service session)))))))

(defun rbridge-session-live-ready-p (session)
  "Return non-nil when SESSION can be reused."
  (and session
       (eq (rbridge-session-state session) 'ready)
       (process-live-p (rbridge-session-process session))))

(defun rbridge-connect (remote service sessions)
  "Connect REMOTE SERVICE, storing reusable state in SESSIONS."
  (rbridge-validate-service service)
  (let* ((key (rbridge-remote-identity remote))
         (existing (gethash key sessions)))
    (if (rbridge-session-live-ready-p existing)
        (progn
          (setf (rbridge-session-last-used existing) (float-time))
          existing)
      (let ((session (or existing
                         (rbridge-session-create
                          :remote remote :service service :state 'absent))))
        (setf (rbridge-session-remote session) remote
              (rbridge-session-service session) service)
        (puthash key session sessions)
        (when (and existing
                   (not (memq (rbridge-session-state session)
                              '(absent dead))))
          (rbridge-disconnect-session session))
        (rbridge-session-transition session 'bootstrapping)
        (condition-case error-data
            (let* ((binary (rbridge-ensure-server remote service))
                   (runtime-directory
                    (rbridge-remote-runtime-directory remote service))
                   (socket-path (format "%s/%s.sock"
                                        runtime-directory
                                        (rbridge-session-id)))
                   (attempt 0)
                   (connected nil))
              (when (> (string-bytes socket-path) 100)
                (error "%s: remote Unix socket path is too long: %s"
                       (rbridge-service-name service) socket-path))
              (setf (rbridge-session-binary-path session) binary
                    (rbridge-session-socket-path session) socket-path)
              (while (and (not connected)
                          (< attempt rbridge-ssh-port-attempts))
                (setq attempt (1+ attempt))
                (when (eq (rbridge-session-state session) 'dead)
                  (rbridge-session-transition session 'bootstrapping))
                (setf (rbridge-session-local-port session)
                      (rbridge-candidate-local-port))
                (rbridge-session-transition session 'starting)
                (rbridge-start-ssh-process session)
                (rbridge-session-transition session 'waiting-health)
                (condition-case attempt-error
                    (let ((health (rbridge-wait-for-health session)))
                      (setf (rbridge-session-capabilities session)
                            (alist-get 'capabilities health))
                      (rbridge-session-transition session 'ready)
                      (setq connected t))
                  (error
                   (when (process-live-p (rbridge-session-process session))
                     (delete-process (rbridge-session-process session))
                     (accept-process-output
                      (rbridge-session-process session) 0.05))
                   (unless (eq (rbridge-session-state session) 'dead)
                     (rbridge-session-transition session 'dead))
                   (when (or (= attempt rbridge-ssh-port-attempts)
                             (not (string-match-p
                                   "SSH exited before"
                                   (error-message-string attempt-error))))
                     (signal (car attempt-error) (cdr attempt-error))))))
              (unless connected
                (error "%s: exhausted SSH local port attempts"
                       (rbridge-service-name service)))
              session)
          (error
           (unless (eq (rbridge-session-state session) 'dead)
             (rbridge-session-transition session 'dead))
           (signal (car error-data) (cdr error-data))))))))

(defun rbridge-disconnect-session (session)
  "Stop SESSION and mark it dead."
  (when-let* ((process (rbridge-session-process session)))
    (when (process-live-p process)
      (delete-process process)
      (accept-process-output process 0.1)))
  (unless (eq (rbridge-session-state session) 'dead)
    (rbridge-session-transition session 'dead))
  session)

(defun rbridge-disconnect-remote (remote sessions)
  "Disconnect REMOTE session stored in SESSIONS."
  (when-let* ((session (gethash (rbridge-remote-identity remote) sessions)))
    (rbridge-disconnect-session session)))

(defun rbridge-session-url (session path)
  "Return SESSION loopback URL for absolute PATH."
  (unless (string-prefix-p "/" path)
    (error "rbridge: endpoint path must be absolute"))
  (format "http://127.0.0.1:%d%s"
          (rbridge-session-local-port session) path))

(provide 'rbridge)

;;; rbridge.el ends here
