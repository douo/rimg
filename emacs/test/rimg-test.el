;;; rimg-test.el --- Tests for rimg -*- lexical-binding: t -*-

(require 'ert)
(require 'image-dired)
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

(ert-deftest rimg-local-thumbnail-cache-is-sharded-and-written-atomically ()
  (let* ((cache-directory (make-temp-file "rimg-local-cache-" t))
         (rimg-local-cache-directory cache-directory)
         (remote (rimg--remote-from-path "/ssh:alice@example:/data/images/"))
         (key (make-string 64 ?a))
         (data (unibyte-string #xff #xd8 #xff #xd9)))
    (unwind-protect
        (let* ((path (rimg--store-local-thumbnail remote key "jpeg" data))
               (identity-hash
                (secure-hash 'sha256 (rimg--remote-identity remote))))
          (should
           (equal path
                  (expand-file-name
                   (format "%s/aa/%s.jpg" identity-hash key)
                   cache-directory)))
          (should (equal (file-modes path) #o600))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally path)
            (should (equal (buffer-string) data)))
          (should-not
           (directory-files-recursively cache-directory "\\.tmp\\.")))
      (delete-directory cache-directory t))))

(ert-deftest rimg-thumbnail-request-stores-response-before-callback ()
  (let* ((cache-directory (make-temp-file "rimg-local-cache-" t))
         (rimg-local-cache-directory cache-directory)
         (rimg-thumbnail-size 256)
         (rimg-thumbnail-jpeg-quality 82)
         (rimg-http-parallelism 3)
         (remote (rimg--remote-from-path "/ssh:alice@example:/data/images/"))
         (tunnel-process (start-process "rimg-test-tunnel" nil
                                        "sh" "-c" "sleep 5"))
         (session (rimg--session-create
                   :remote remote :state 'ready :local-port 55123
                   :process tunnel-process))
         (key (make-string 64 ?b))
         (image-data (unibyte-string #xff #xd8 #xff #xd9))
         request-url request-body request-headers queue-limit callback-path)
    (unwind-protect
        (cl-letf (((symbol-function 'url-queue-retrieve)
                   (lambda (url callback &optional callback-arguments _silent _cookies)
                     (setq request-url url
                           request-body url-request-data
                           request-headers url-request-extra-headers
                           queue-limit url-queue-parallel-processes)
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert "HTTP/1.1 200 OK\r\n")
                       (insert "Content-Type: image/jpeg\r\n")
                       (insert "X-Rimg-Key: " key "\r\n\r\n")
                       (insert image-data)
                       (setq-local url-http-response-status 200)
                       (apply callback nil callback-arguments)))))
          (rimg--request-thumbnail
           session
           "/ssh:alice@example:/data/images/portrait.png"
           (lambda (path) (setq callback-path path)))
          (should (equal request-url "http://127.0.0.1:55123/v1/thumb"))
          (should (equal (cdr (assoc "Content-Type" request-headers))
                         "application/json"))
          (should (equal queue-limit 3))
          (let ((payload
                 (json-parse-string request-body :object-type 'alist)))
            (should (equal (alist-get 'path payload)
                           "/data/images/portrait.png"))
            (should (equal (alist-get 'width payload) 256))
            (should (equal (alist-get 'height payload) 256))
            (should (equal (alist-get 'fit payload) "contain"))
            (should (equal (alist-get 'format payload) "jpeg"))
            (should (equal (alist-get 'quality payload) 82)))
          (should (file-regular-p callback-path))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally callback-path)
            (should (equal (buffer-string) image-data))))
      (when (process-live-p tunnel-process)
        (delete-process tunnel-process))
      (delete-directory cache-directory t))))

(ert-deftest rimg-local-cache-revalidates-without-thumbnail-body ()
  (let* ((cache-directory (make-temp-file "rimg-local-cache-" t))
         (rimg-local-cache-directory cache-directory)
         (remote (rimg--remote-from-path "/ssh:alice@example:/data/images/"))
         (tunnel-process (start-process "rimg-test-tunnel" nil
                                        "sh" "-c" "sleep 5"))
         (session (rimg--session-create
                   :remote remote :state 'ready :local-port 55123
                   :process tunnel-process))
         (key (make-string 64 ?c))
         (image-data (unibyte-string #xff #xd8 #xff #xd9))
         (request-count 0)
         second-request-headers callback-paths request-errors)
    (unwind-protect
        (cl-letf (((symbol-function 'url-queue-retrieve)
                   (lambda (_url callback &optional callback-arguments _silent _cookies)
                     (setq request-count (1+ request-count))
                     (when (= request-count 2)
                       (setq second-request-headers url-request-extra-headers))
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (if (= request-count 1)
                           (progn
                             (insert "HTTP/1.1 200 OK\r\n")
                             (setq-local url-http-response-status 200))
                         (insert "HTTP/1.1 200 OK\r\n")
                         (insert "X-Rimg-Not-Modified: true\r\n")
                         (setq-local url-http-response-status 200))
                       (insert "X-Rimg-Key: " key "\r\n\r\n")
                       (when (= request-count 1)
                         (insert image-data))
                       (apply callback nil callback-arguments)))))
          (dotimes (_ 2)
            (rimg--request-thumbnail
             session
             "/ssh:alice@example:/data/images/portrait.png"
             (lambda (path) (push path callback-paths))
             (lambda (error-data) (push error-data request-errors))))
          (should-not request-errors)
          (should (= request-count 2))
          (should (equal (cdr (assoc "If-None-Match" second-request-headers))
                         (format "\"%s\"" key)))
          (should (= (length callback-paths) 2))
          (should (equal (car callback-paths) (cadr callback-paths)))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally (car callback-paths))
            (should (equal (buffer-string) image-data))))
      (when (process-live-p tunnel-process)
        (delete-process tunnel-process))
      (delete-directory cache-directory t))))

(ert-deftest rimg-gallery-first-page-is-bounded-and-retains-remote-originals ()
  (let* ((temp-root (make-temp-file "rimg-gallery-" t))
         (thumbnail-file (expand-file-name "thumb.png" temp-root))
         (image-dired-dir (expand-file-name "image-dired/" temp-root))
         (image-dired-tags-db-file
          (expand-file-name "tags.db" image-dired-dir))
         (image-dired-thumbnail-buffer "*rimg-test-thumbnails*")
         (rimg-page-size 2)
         (remote (rimg--remote-from-path "/ssh:alice@example:/data/images/"))
         (session (rimg--session-create :remote remote :state 'ready))
         (dired-buffer (generate-new-buffer " *rimg-test-dired*"))
         (files '("/ssh:alice@example:/data/images/a.jpg"
                  "/ssh:alice@example:/data/images/b.jpg"
                  "/ssh:alice@example:/data/images/c.jpg"))
         requested thumbnail-buffer originals)
    (unwind-protect
        (progn
          (with-temp-file thumbnail-file
            (set-buffer-multibyte nil)
            (insert
             (base64-decode-string
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")))
          (cl-letf (((symbol-function 'rimg--request-thumbnail)
                     (lambda (_session original callback &optional _error-callback)
                       (push original requested)
                       (funcall callback thumbnail-file)))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer)))
            (setq thumbnail-buffer
                  (rimg--display-gallery session dired-buffer files)))
          (should (equal (nreverse requested) (seq-take files 2)))
          (with-current-buffer thumbnail-buffer
            (goto-char (point-min))
            (while (not (eobp))
              (when (image-dired-image-at-point-p)
                (push (image-dired-original-file-name) originals))
              (forward-char 1)))
          (should (equal (nreverse originals) (seq-take files 2)))
          (setq requested nil originals nil)
          (cl-letf (((symbol-function 'rimg--request-thumbnail)
                     (lambda (_session original callback &optional _error-callback)
                       (push original requested)
                       (funcall callback thumbnail-file)))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer)))
            (with-current-buffer thumbnail-buffer
              (rimg-next-page)))
          (should (equal requested (last files)))
          (with-current-buffer thumbnail-buffer
            (should (= rimg--gallery-page-index 1))
            (goto-char (point-min))
            (while (not (eobp))
              (when (image-dired-image-at-point-p)
                (push (image-dired-original-file-name) originals))
              (forward-char 1)))
          (should (equal originals (last files))))
      (when (buffer-live-p thumbnail-buffer)
        (kill-buffer thumbnail-buffer))
      (when (buffer-live-p dired-buffer)
        (kill-buffer dired-buffer))
      (delete-directory temp-root t))))

(ert-deftest rimg-dired-image-files-use-the-existing-listing ()
  (let* ((directory (make-temp-file "rimg-dired-files-" t))
         (wanted (mapcar (lambda (name) (expand-file-name name directory))
                         '("a.jpg" "b.PNG" "c.webp")))
         (ignored (expand-file-name "notes.txt" directory))
         (fake-image-directory (expand-file-name "folder.jpg" directory))
         dired-buffer)
    (unwind-protect
        (progn
          (dolist (file (append wanted (list ignored)))
            (with-temp-file file (insert "fixture")))
          (make-directory fake-image-directory)
          (setq dired-buffer (dired-noselect directory))
          (with-current-buffer dired-buffer
            (should (equal (rimg--dired-image-files) wanted))))
      (when (buffer-live-p dired-buffer)
        (kill-buffer dired-buffer))
      (delete-directory directory t))))

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
             (regexp-quote "--exit-on-stdin-eof")
             (car (last command))))
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

(ert-deftest rimg-e2e-dired-gallery-reuses-local-thumbnail-body ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((temp-root (make-temp-file "rimg-gallery-e2e-" t))
           (rimg--sessions (make-hash-table :test #'equal))
           (rimg-local-cache-directory
            (expand-file-name "cache/" temp-root))
           (rimg-page-size 3)
           (image-dired-dir (expand-file-name "image-dired/" temp-root))
           (image-dired-tags-db-file
            (expand-file-name "tags.db" image-dired-dir))
           (image-dired-thumbnail-buffer "*rimg-e2e-thumbnails*")
           (original-store (symbol-function 'rimg--store-local-thumbnail))
           (original-gallery-error
            (symbol-function 'rimg--gallery-thumbnail-error))
           (store-count 0)
           request-errors
           dired-buffer thumbnail-buffer session)
      (unwind-protect
          (cl-letf (((symbol-function 'rimg--store-local-thumbnail)
                     (lambda (&rest arguments)
                       (setq store-count (1+ store-count))
                       (apply original-store arguments)))
                    ((symbol-function 'rimg--gallery-thumbnail-error)
                     (lambda (buffer marker generation error-data)
                       (push (error-message-string error-data) request-errors)
                       (funcall original-gallery-error
                                buffer marker generation error-data))))
            (setq dired-buffer (dired-noselect remote-directory))
            (setq thumbnail-buffer
                  (with-current-buffer dired-buffer (rimg-dired)))
            (setq session
                  (buffer-local-value 'rimg--gallery-session thumbnail-buffer))
            (with-current-buffer thumbnail-buffer
              (let ((deadline (+ (float-time) 30)))
                (while (and (plusp rimg--gallery-pending)
                            (< (float-time) deadline))
                  (when url-queue
                    (url-queue-run-queue))
                  (accept-process-output nil 0.05)
                  (sit-for 0.01)))
              (should (zerop rimg--gallery-pending))
              (should-not request-errors)
              (should (= image-dired--number-of-thumbnails 3)))
            (should (= store-count 3))
            (with-current-buffer thumbnail-buffer
              (rimg--render-gallery-page thumbnail-buffer)
              (let ((deadline (+ (float-time) 30)))
                (while (and (plusp rimg--gallery-pending)
                            (< (float-time) deadline))
                  (when url-queue
                    (url-queue-run-queue))
                  (accept-process-output nil 0.05)
                  (sit-for 0.01)))
              (should (zerop rimg--gallery-pending))
              (should-not request-errors)
              (should (= image-dired--number-of-thumbnails 3)))
            (should (= store-count 3)))
        (when session
          (rimg--disconnect-session session))
        (when (buffer-live-p thumbnail-buffer)
          (kill-buffer thumbnail-buffer))
        (when (buffer-live-p dired-buffer)
          (kill-buffer dired-buffer))
        (delete-directory temp-root t)))))

(provide 'rimg-test)

;;; rimg-test.el ends here
