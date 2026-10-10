;;; rbridge-test.el --- Tests for rbridge -*- lexical-binding: t -*-

(require 'ert)
(require 'rbridge)

(defun rbridge-test--service ()
  "Return a representative test service."
  (rbridge-service-create
   :name "rvid"
   :binary-name "rvidd"
   :version "0.1.0"
   :protocol 1
   :binary-directory "/tmp/dist"
   :remote-install-directory "~/.cache/rvid/bin"
   :ssh-options '("-o" "Compression=no")))

(ert-deftest rbridge-parses-a-single-hop-remote-identity ()
  (let ((first (rbridge-remote-from-path
                "/ssh:alice@example#2222:/srv/a.mp4"))
        (second (rbridge-remote-from-path
                 "/ssh:alice@example#2222:/srv/b.mp4")))
    (should (equal (rbridge-remote-user first) "alice"))
    (should (equal (rbridge-remote-host first) "example"))
    (should (equal (rbridge-remote-port first) "2222"))
    (should (equal (rbridge-remote-identity first)
                   (rbridge-remote-identity second)))))

(ert-deftest rbridge-builds-versioned-platform-artifacts ()
  (let ((service (rbridge-test--service)))
    (should (equal (rbridge-artifact-name service "Linux" "x86_64")
                   "rvidd-linux-amd64"))
    (should (equal (rbridge-artifact-name service "Linux" "aarch64")
                   "rvidd-linux-arm64"))
    (should (equal (rbridge-server-install-localname service)
                   "~/.cache/rvid/bin/0.1.0/rvidd"))
    (should-error (rbridge-artifact-name service "Darwin" "arm64")
                  :type 'user-error)))

(ert-deftest rbridge-ssh-command-keeps-payload-inside-loopback-forward ()
  (let* ((service (rbridge-test--service))
         (remote (rbridge-remote-from-path
                  "/ssh:alice@example#2222:/srv/movie.mp4"))
         (command
          (rbridge-ssh-command
           remote service 55123 "/tmp/rvid-1000/session.sock"
           "/home/alice/.cache/rvid/bin/0.1.0/rvidd"
           '("--auth-token" "secret"))))
    (should (member "Compression=no" command))
    (should (member
             "127.0.0.1:55123:/tmp/rvid-1000/session.sock"
             command))
    (should (member "alice@example" command))
    (should (string-match-p "--auth-token secret"
                            (car (last command))))
    (should (string-match-p "--exit-on-stdin-eof"
                            (car (last command))))))

(ert-deftest rbridge-health-enforces-the-service-protocol ()
  (let ((service (rbridge-test--service)))
    (should (alist-get
             'ok
             (rbridge-parse-health
              "{\"ok\":true,\"protocol\":1,\"capabilities\":{\"media_range\":true}}"
              service)))
    (should-error
     (rbridge-parse-health "{\"ok\":true,\"protocol\":2}" service)
     :type 'rbridge-protocol-error)))

(ert-deftest rbridge-redacts-service-secrets-from-diagnostic-arguments ()
  (should
   (equal
    (rbridge--redact-arguments
     '("--auth-token" "secret" "--max-open" "10")
     '("--auth-token"))
    '("--auth-token" "<redacted>" "--max-open" "10"))))

(provide 'rbridge-test)

(ert-deftest rbridge-upgrade-installs-new-version-and-reuses-verified-binary ()
  (let* ((remote (rbridge-remote-from-path "/ssh:alice@example:/srv/song.mp3"))
         (service (rbridge-test--service))
         (installed-version "0.1.0")
         installs)
    (setf (rbridge-service-version service) "0.1.1")
    (cl-letf (((symbol-function 'rbridge-remote-expanded-localname)
               (lambda (_remote path) path))
              ((symbol-function 'rbridge-remote-file-name)
               (lambda (_remote _path) shell-file-name))
              ((symbol-function 'rbridge-remote-process-output)
               (lambda (&rest _args)
                 (format "{\"version\":\"%s\",\"protocol\":1}" installed-version)))
              ((symbol-function 'rbridge-local-server-artifact)
               (lambda (&rest _args) "/tmp/dist/rvidd-linux-amd64"))
              ((symbol-function 'rbridge-install-server)
               (lambda (_remote _service artifact path)
                 (push (list artifact path) installs)
                 (setq installed-version "0.1.1"))))
      (should (equal (rbridge-ensure-server remote service)
                     "~/.cache/rvid/bin/0.1.1/rvidd"))
      (should (equal installs '(("/tmp/dist/rvidd-linux-amd64"
                                "~/.cache/rvid/bin/0.1.1/rvidd"))))
      (rbridge-ensure-server remote service)
      (should (= (length installs) 1)))))

;;; rbridge-test.el ends here
