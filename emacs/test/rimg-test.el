;;; rimg-test.el --- Tests for rimg -*- lexical-binding: t -*-

(require 'ert)
(require 'image-dired)
(require 'rimg)

(defun rimg-test--sync-thumbnail-response (session path width height quality)
  "Request PATH through SESSION and return selected response fields."
  (let* ((url-proxy-services nil)
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data
          (json-serialize
           (list (cons 'path path) (cons 'width width) (cons 'height height)
                 (cons 'fit "contain") (cons 'format "jpeg")
                 (cons 'quality quality))))
         (buffer
          (url-retrieve-synchronously
           (format "http://127.0.0.1:%d/v1/thumb"
                   (rimg--session-local-port session))
           t t 10)))
    (unless buffer
      (error "rimg test: thumbnail request timed out"))
    (unwind-protect
        (with-current-buffer buffer
          (let* ((body-start (rimg--response-body-start))
                 (key (rimg--response-header "X-Rimg-Key" body-start))
                 (cache (rimg--response-header "X-Rimg-Cache" body-start))
                 (body (buffer-substring-no-properties body-start (point-max))))
            (list (cons 'status url-http-response-status)
                  (cons 'key key) (cons 'cache cache) (cons 'body body))))
      (kill-buffer buffer))))

(defun rimg-test--remote-socket-exists-p (remote socket-path)
  "Return non-nil when SOCKET-PATH currently exists as a socket on REMOTE."
  (let ((default-directory (rimg--remote-file-name remote "~/")))
    (zerop (process-file "test" nil nil nil "-S" socket-path))))

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
         requested prepared thumbnail-buffer originals)
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
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'rimg--request-prepare)
                     (lambda (_session page-files)
                       (setq prepared page-files))))
            (setq thumbnail-buffer
                  (rimg--display-gallery session dired-buffer files)))
          (should (equal (nreverse requested) (seq-take files 2)))
          (should (equal prepared (seq-take files 2)))
          (with-current-buffer thumbnail-buffer
            (goto-char (point-min))
            (while (not (eobp))
              (when (image-dired-image-at-point-p)
                (push (image-dired-original-file-name) originals))
              (forward-char 1)))
          (should (equal (nreverse originals) (seq-take files 2)))
          (setq requested nil prepared nil originals nil)
          (cl-letf (((symbol-function 'rimg--request-thumbnail)
                     (lambda (_session original callback &optional _error-callback)
                       (push original requested)
                       (funcall callback thumbnail-file)))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'rimg--request-prepare)
                     (lambda (_session page-files)
                       (setq prepared page-files))))
            (with-current-buffer thumbnail-buffer
              (rimg-next-page)))
          (should (equal requested (last files)))
          (should (equal prepared (last files)))
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

(ert-deftest rimg-open-preview-displays-local-proxy-instead-of-remote-original ()
  (let* ((remote (rimg--remote-from-path "/ssh:alice@example:/data/images/"))
         (session (rimg--session-create :remote remote :state 'ready))
         (original "/ssh:alice@example:/data/images/portrait.jpg")
         (preview "/tmp/rimg-preview.jpg")
         requested displayed
         (buffer (generate-new-buffer " *rimg-preview-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (image-dired-thumbnail-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "x"
                                'image-dired-thumbnail t
                                'original-file-name original)))
          (goto-char (point-min))
          (setq rimg--gallery-session session)
          (rimg-thumbnail-mode 1)
          (cl-letf (((symbol-function 'rimg--request-preview)
                     (lambda (_session file callback &optional _error-callback)
                       (setq requested file)
                       (funcall callback preview)))
                    ((symbol-function 'image-dired-display-image)
                     (lambda (file &optional _ignored)
                       (setq displayed file))))
            (rimg-open-preview))
          (should (equal requested original))
          (should (equal displayed preview))
          (should-not (file-remote-p displayed))
          (setq displayed nil)
          (cl-letf (((symbol-function 'image-dired-display-image)
                     (lambda (file &optional _ignored)
                       (setq displayed file))))
            (rimg-open-original))
          (should (equal displayed original))
          (should (file-remote-p displayed))
          (should (eq (lookup-key rimg-thumbnail-mode-map (kbd "RET"))
                      #'rimg-open-preview)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest rimg-clear-local-cache-removes-only-the-current-remote ()
  (let* ((cache-directory (make-temp-file "rimg-clear-cache-" t))
         (rimg-local-cache-directory cache-directory)
         (first (rimg--remote-from-path "/ssh:alice@first:/images/"))
         (second (rimg--remote-from-path "/ssh:alice@second:/images/"))
         (key (make-string 64 ?d))
         (first-path (rimg--store-local-thumbnail first key "jpeg" "first"))
         (second-path (rimg--store-local-thumbnail second key "jpeg" "second"))
         (buffer (generate-new-buffer " *rimg-clear-cache-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq rimg--gallery-session
                (rimg--session-create :remote first :state 'ready))
          (rimg-thumbnail-mode 1)
          (rimg-clear-local-cache)
          (should-not (file-exists-p first-path))
          (should (file-exists-p second-path)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory cache-directory t))))

(ert-deftest rimg-prune-remote-cache-uses-the-current-session-paths ()
  (let* ((remote (rimg--remote-from-path "/ssh:alice@example:/images/"))
         (session (rimg--session-create
                   :remote remote :state 'ready
                   :binary-path "/home/alice/.cache/rimg/bin/0.1.0/rimgd"
                   :cache-dir "/home/alice/.cache/rimg/thumbs"))
         (rimg-remote-cache-max-age-days 14)
         (rimg-remote-cache-max-size-bytes 1048576)
         (buffer (generate-new-buffer " *rimg-prune-test*"))
         invocation)
    (unwind-protect
        (with-current-buffer buffer
          (setq rimg--gallery-session session)
          (rimg-thumbnail-mode 1)
          (cl-letf (((symbol-function 'rimg--remote-process-output)
                     (lambda (called-remote program &rest arguments)
                       (setq invocation
                             (list called-remote program arguments))
                       "{\"removed_files\":3,\"freed_bytes\":4096,\"remaining_bytes\":512}")))
            (let ((result (rimg-prune-remote-cache)))
              (should (= (alist-get 'removed_files result) 3))))
          (should (eq (car invocation) remote))
          (should (equal (cadr invocation)
                         "/home/alice/.cache/rimg/bin/0.1.0/rimgd"))
          (should
           (equal (caddr invocation)
                  '("prune" "--cache-dir" "/home/alice/.cache/rimg/thumbs"
                    "--max-age" "336h" "--max-size-bytes" "1048576"
                    "--json"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

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
                  "\"encode\":[\"jpeg\",\"png\"],\"prepare\":true}}"))))
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
           request-errors preview-errors preview-paths
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
            (should (alist-get 'prepare (rimg--session-capabilities session)))
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
            (should (= store-count 3))
            (let ((original
                   (car (buffer-local-value
                         'rimg--gallery-files thumbnail-buffer))))
              (dotimes (_ 2)
                (let ((done nil))
                  (rimg--request-preview
                   session original
                   (lambda (path)
                     (push path preview-paths)
                     (setq done t))
                   (lambda (error-data)
                     (push error-data preview-errors)
                     (setq done t)))
                  (let ((deadline (+ (float-time) 30)))
                    (while (and (not done) (< (float-time) deadline))
                      (when url-queue
                        (url-queue-run-queue))
                      (accept-process-output nil 0.05)
                      (sit-for 0.01)))
                  (should done))))
            (should-not preview-errors)
            (should (= store-count 4))
            (should (= (length preview-paths) 2))
            (should (equal (car preview-paths) (cadr preview-paths)))
            (should (file-regular-p (car preview-paths))))
        (when session
          (rimg--disconnect-session session))
        (when (buffer-live-p thumbnail-buffer)
          (kill-buffer thumbnail-buffer))
        (when (buffer-live-p dired-buffer)
          (kill-buffer dired-buffer))
        (delete-directory temp-root t)))))

(ert-deftest rimg-e2e-two-sessions-use-distinct-sockets-and-share-remote-cache ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((remote (rimg--remote-from-path remote-directory))
           (first-sessions (make-hash-table :test #'equal))
           (second-sessions (make-hash-table :test #'equal))
           (fixture
            (expand-file-name "sample.jpg" remote-directory))
           first second)
      (unwind-protect
          (progn
            (setq first
                  (let ((rimg--sessions first-sessions))
                    (rimg--connect-remote remote)))
            (setq second
                  (let ((rimg--sessions second-sessions))
                    (rimg--connect-remote remote)))
            (should-not (equal (rimg--session-socket-path first)
                               (rimg--session-socket-path second)))
            (should-not (= (rimg--session-local-port first)
                           (rimg--session-local-port second)))
            (dolist (session (list first second))
              (let* ((health (rimg--request-health session))
                     (pid (alist-get 'pid health))
                     (port (rimg--session-local-port session))
                     (local-listeners
                      (with-temp-buffer
                        (let ((status
                               (process-file
                                "/usr/sbin/lsof" nil (current-buffer) nil
                                "-nP" "-a" (format "-iTCP:%d" port)
                                "-sTCP:LISTEN")))
                          (should (zerop status))
                          (buffer-string))))
                     (remote-tcp
                      (rimg--remote-process-output remote "ss" "-ltnp"))
                     (remote-unix
                      (rimg--remote-process-output remote "ss" "-lxnp")))
                (should
                 (string-match-p
                  (regexp-quote (format "127.0.0.1:%d" port))
                  local-listeners))
                (should-not
                 (string-match-p (format "pid=%d," pid) remote-tcp))
                (should
                 (string-match-p (format "pid=%d," pid) remote-unix))
                (should
                 (string-match-p
                  (regexp-quote (rimg--session-socket-path session))
                  remote-unix))))
            (rimg--remote-process-output
             remote (rimg--session-binary-path first) "prune"
             "--cache-dir" (rimg--session-cache-dir first)
             "--max-age" "1ns" "--json")
            (let* ((path (file-remote-p fixture 'localname))
                   (cold (rimg-test--sync-thumbnail-response
                          first path 137 139 79))
                   (warm (rimg-test--sync-thumbnail-response
                          second path 137 139 79)))
              (should (equal (alist-get 'status cold) 200))
              (should (equal (alist-get 'cache cold) "MISS"))
              (should (equal (alist-get 'cache warm) "HIT"))
              (should (equal (alist-get 'key cold) (alist-get 'key warm)))
              (should (equal (alist-get 'body cold) (alist-get 'body warm)))))
        (when first
          (rimg--disconnect-session first))
        (when second
          (rimg--disconnect-session second))))))

(ert-deftest rimg-e2e-forced-ssh-loss-marks-dead-and-cleans-remote-socket ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((rimg--sessions (make-hash-table :test #'equal))
           (remote (rimg--remote-from-path remote-directory))
           (session (rimg--connect-remote remote))
           (socket (rimg--session-socket-path session)))
      (unwind-protect
          (progn
            (should (rimg-test--remote-socket-exists-p remote socket))
            (delete-process (rimg--session-process session))
            (let ((deadline (+ (float-time) 5)))
              (while (and (not (eq (rimg--session-state session) 'dead))
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq (rimg--session-state session) 'dead))
            (let ((deadline (+ (float-time) 5)))
              (while (and (rimg-test--remote-socket-exists-p remote socket)
                          (< (float-time) deadline))
                (sleep-for 0.05)))
            (should-not (rimg-test--remote-socket-exists-p remote socket)))
        (when (process-live-p (rimg--session-process session))
          (rimg--disconnect-session session))))))

(ert-deftest rimg-e2e-remote-mtime-change-invalidates-thumbnail-key ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((rimg--sessions (make-hash-table :test #'equal))
           (remote (rimg--remote-from-path remote-directory))
           (fixture
            (file-remote-p
             (expand-file-name "sample.jpg" remote-directory)
             'localname))
           (temporary-directory
            (rimg--remote-process-output
             remote "mktemp" "-d" "/tmp/rimg-e2e-XXXXXXXX"))
           (temporary-path
            (expand-file-name "fixture.jpg" temporary-directory))
           (temporary-file (rimg--remote-file-name remote temporary-path))
           session)
      (unwind-protect
          (progn
            (rimg--remote-process-output
             remote "cp" "--" fixture temporary-path)
            (setq session (rimg--connect-remote remote))
            (let ((first (rimg-test--sync-thumbnail-response
                          session temporary-path 143 149 78)))
              (should (equal (alist-get 'cache first) "MISS"))
              (sleep-for 0.01)
              (rimg--remote-process-output remote "touch" "-m" temporary-path)
              (let ((second (rimg-test--sync-thumbnail-response
                             session temporary-path 143 149 78)))
                (should (equal (alist-get 'cache second) "MISS"))
                (should-not (equal (alist-get 'key first)
                                   (alist-get 'key second))))))
        (when session
          (rimg--disconnect-session session))
        (when (file-exists-p temporary-file)
          (delete-file temporary-file))
        (let ((remote-temp-directory
               (rimg--remote-file-name remote temporary-directory)))
          (when (file-directory-p remote-temp-directory)
            (delete-directory remote-temp-directory)))))))

(ert-deftest rimg-e2e-records-cold-remote-warm-and-local-warm-measurements ()
  :tags '(integration)
  (let ((remote-directory (getenv "RIMG_E2E_REMOTE")))
    (unless remote-directory
      (ert-skip "RIMG_E2E_REMOTE is not set"))
    (let* ((temp-root (make-temp-file "rimg-perf-e2e-" t))
           (rimg--sessions (make-hash-table :test #'equal))
           (rimg-local-cache-directory (expand-file-name "cache/" temp-root))
           (remote (rimg--remote-from-path remote-directory))
           (fixture
            (expand-file-name "sample.jpg" remote-directory))
           (original-store (symbol-function 'rimg--store-local-thumbnail))
           body-writes session)
      (unwind-protect
          (progn
            (setq session (rimg--connect-remote remote))
            (rimg--remote-process-output
             remote (rimg--session-binary-path session) "prune"
             "--cache-dir" (rimg--session-cache-dir session)
             "--max-age" "1ns" "--json")
            (cl-labels
                ((fetch ()
                   (let ((started (float-time)) done request-error)
                     (rimg--request-thumbnail
                      session fixture (lambda (_path) (setq done t))
                      (lambda (error-data)
                        (setq request-error error-data done t)))
                     (let ((deadline (+ (float-time) 30)))
                       (while (and (not done) (< (float-time) deadline))
                         (when url-queue
                           (url-queue-run-queue))
                         (accept-process-output nil 0.05)
                         (sit-for 0.01)))
                     (should done)
                     (should-not request-error)
                     (- (float-time) started))))
              (cl-letf (((symbol-function 'rimg--store-local-thumbnail)
                         (lambda (called-remote key format data)
                           (push (string-bytes data) body-writes)
                           (funcall original-store
                                    called-remote key format data))))
                (let ((cold-seconds (fetch)))
                  (delete-directory
                   (rimg--local-remote-cache-directory remote) t)
                  (let ((remote-warm-seconds (fetch))
                        local-warm-seconds)
                    (setq local-warm-seconds (fetch))
                    (should (= (length body-writes) 2))
                    (should (= (car body-writes) (cadr body-writes)))
                    (princ
                     (format
                      (concat "RIMG_E2E_PERF original_bytes=%d body_bytes=%d "
                              "cold_seconds=%.6f remote_warm_seconds=%.6f "
                              "local_warm_seconds=%.6f local_warm_body_writes=0\n")
                      (file-attribute-size (file-attributes fixture))
                      (car body-writes)
                      cold-seconds remote-warm-seconds local-warm-seconds)))))))
        (when session
          (rimg--disconnect-session session))
        (delete-directory temp-root t)))))

(provide 'rimg-test)

;;; rimg-test.el ends here
