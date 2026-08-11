;;; rimg-test.el --- Tests for rimg -*- lexical-binding: t -*-

(require 'ert)
(require 'rimg)

(ert-deftest rimg-remote-identity-is-stable-per-ssh-target ()
  (let ((first (rimg--remote-from-path
                "/ssh:alice@example:/data/outputs/a/"))
        (second (rimg--remote-from-path
                 "/ssh:alice@example:/mnt/images/b/")))
    (should (equal (rimg--remote-method first) "ssh"))
    (should (equal (rimg--remote-user first) "alice"))
    (should (equal (rimg--remote-host first) "example"))
    (should (equal (rimg--remote-localname first) "/data/outputs/a/"))
    (should (equal (rimg--remote-identity first)
                   (rimg--remote-identity second)))))

(ert-deftest rimg-remote-detection-rejects-unsupported-paths ()
  (should-error (rimg--remote-from-path "/tmp/images/") :type 'user-error)
  (should-error (rimg--remote-from-path "/sudo::/tmp/images/") :type 'user-error)
  (should-error
   (rimg--remote-from-path "/ssh:jump|ssh:target:/data/images/")
   :type 'user-error))

(ert-deftest rimg-server-artifact-selection-supports-mvp-linux-targets ()
  (should (equal (rimg--server-artifact-name "Linux" "x86_64")
                 "rimgd-linux-amd64"))
  (should (equal (rimg--server-artifact-name "Linux" "aarch64")
                 "rimgd-linux-arm64"))
  (should-error (rimg--server-artifact-name "Darwin" "arm64")
                :type 'user-error)
  (should-error (rimg--server-artifact-name "Linux" "riscv64")
                :type 'user-error))

(ert-deftest rimg-server-install-path-is-versioned ()
  (should (equal (rimg--server-install-localname)
                 "~/.cache/rimg/bin/0.1.0/rimgd")))

(ert-deftest rimg-ssh-command-forwards-loopback-to-remote-unix-socket ()
  (let* ((remote (rimg--remote-from-path
                  "/ssh:alice@example#2222:/data/images/"))
         (command (rimg--ssh-command
                   remote
                   55123
                   "/tmp/rimg-1000/a82f719bc31d.sock"
                   "/home/alice/.cache/rimg/bin/0.1.0/rimgd"
                   "/home/alice/.cache/rimg/thumbs")))
    (should (equal (car command) "ssh"))
    (should (member "-T" command))
    (should (member "ExitOnForwardFailure=yes" command))
    (should (member
             "127.0.0.1:55123:/tmp/rimg-1000/a82f719bc31d.sock"
             command))
    (should (member "2222" command))
    (should (member "alice@example" command))
    (should-not (member "-N" command))
    (should (string-match-p
             (regexp-quote
              "exec /home/alice/.cache/rimg/bin/0.1.0/rimgd serve")
             (car (last command))))))

(ert-deftest rimg-session-state-machine-rejects-invalid-transitions ()
  (let ((session (rimg--session-create :state 'absent)))
    (dolist (state '(bootstrapping starting waiting-health ready dead))
      (rimg--session-transition session state)
      (should (eq (rimg--session-state session) state)))
    (should-error (rimg--session-transition session 'ready))
    (rimg--session-transition session 'bootstrapping)
    (should (eq (rimg--session-state session) 'bootstrapping))))

(ert-deftest rimg-health-parser-enforces-protocol-readiness ()
  (let ((health (rimg--parse-health
                 (concat
                  "{\"ok\":true,\"protocol\":1,\"version\":\"0.1.0\","
                  "\"pid\":42,\"capabilities\":{"
                  "\"decode\":[\"jpeg\",\"png\",\"webp\"],"
                  "\"encode\":[\"jpeg\",\"png\"],\"prepare\":false}}"))))
    (should (equal (alist-get 'version health) "0.1.0"))
    (should (equal (alist-get 'decode (alist-get 'capabilities health))
                   '("jpeg" "png" "webp"))))
  (should-error
   (rimg--parse-health
    "{\"ok\":true,\"protocol\":2,\"version\":\"0.2.0\"}")
   :type 'rimg-protocol-error)
  (should-error
   (rimg--parse-health
   "{\"ok\":false,\"protocol\":1,\"version\":\"0.1.0\"}")
   :type 'rimg-protocol-error))

(ert-deftest rimg-ssh-process-exit-marks-session-dead ()
  (let* ((session (rimg--session-create :state 'ready))
         (process (start-process "rimg-test-exit" nil
                                 "sh" "-c" "exit 0")))
    (setf (rimg--session-process session) process)
    (rimg--attach-process-sentinel session process)
    (while (process-live-p process)
      (accept-process-output process 0.1))
    (accept-process-output process 0.1)
    (should (eq (rimg--session-state session) 'dead))))

(ert-deftest rimg-local-port-candidates-stay-in-ephemeral-range ()
  (dotimes (_ 100)
    (let ((port (rimg--candidate-local-port)))
      (should (<= 49152 port))
      (should (<= port 65535)))))

(ert-deftest rimg-e2e-bootstrap-connects-and-disconnects ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((rimg--sessions (make-hash-table :test #'equal))
           (rimg-bootstrap-enabled t)
           (remote (rimg--remote-from-path remote-directory))
           (session nil))
      (unwind-protect
          (progn
            (setq session (rimg--connect-remote remote))
            (should (eq (rimg--session-state session) 'ready))
            (should (process-live-p (rimg--session-process session)))
            (should (<= 49152 (rimg--session-local-port session) 65535))
            (should (equal (alist-get 'protocol (rimg--request-health session))
                           rimg-protocol-version))
            (should (file-executable-p
                     (rimg--remote-file-name
                      remote (rimg--server-install-localname)))))
        (when session
          (rimg--disconnect-session session)))
      (should (or (null session)
                  (eq (rimg--session-state session) 'dead))))))

(provide 'rimg-test)

;;; rimg-test.el ends here
