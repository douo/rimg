;;; rvid-test.el --- Tests for rvid -*- lexical-binding: t -*-

(require 'ert)
(require 'rvid)

(ert-deftest rvid-service-startup-enables-private-range-serving ()
  (let* ((rvid-token-idle-ttl "12h")
         (rvid-max-open-media 32)
         (service (rvid--bridge-service))
         (remote (rvid--remote-from-path
                  "/ssh:alice@example:/srv/movie.mp4"))
         (session (rbridge-session-create
                   :remote remote :service service :state 'starting))
         (arguments
          (funcall (rbridge-service-serve-arguments-function service)
                   session)))
    (should (equal (rbridge-service-binary-name service) "rvidd"))
    (should (equal (rbridge-server-install-localname service)
                   "~/.cache/rvid/bin/0.1.0/rvidd"))
    (should (member "--auth-token" arguments))
    (should (member "12h" arguments))
    (should (member "32" arguments))
    (should (= (length (rvid--session-auth-token session)) 64))))

(ert-deftest rvid-register-media-sends-only-control-json-through-emacs ()
  (let* ((remote (rvid--remote-from-path
                  "/ssh:alice@example:/srv/movie.mp4"))
         (service (rvid--bridge-service))
         (session
          (rbridge-session-create
           :remote remote :service service :state 'ready :local-port 55123
           :metadata '(:auth-token "session-secret")))
         request-url request-method request-headers request-body)
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (url &optional _silent _inhibit-cookies _timeout)
                 (setq request-url url
                       request-method url-request-method
                       request-headers url-request-extra-headers
                       request-body url-request-data)
                 (let ((buffer (generate-new-buffer " *rvid-open-response*")))
                   (with-current-buffer buffer
                     (setq-local url-http-response-status 201)
                     (insert
                      (concat
                       "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n"
                       "{\"id\":\"capability\",\"name\":\"movie.mp4\","
                       "\"size\":1024,\"mtime_ns\":42,\"etag\":\"tag\","
                       "\"url_path\":\"/v1/media/capability/movie.mp4\","
                       "\"content_type\":\"video/mp4\"}"))
                   buffer)))))
      (let ((registration (rvid--register-media session "/srv/movie.mp4")))
        (should (equal (rvid-registration-id registration) "capability"))
        (should (equal (rvid-registration-size registration) 1024)))
      (should (equal request-url
                     "http://127.0.0.1:55123/v1/media/open"))
      (should (equal request-method "POST"))
      (should (equal (cdr (assoc "Authorization" request-headers))
                     "Bearer session-secret"))
      (should (equal
               (alist-get 'path
                          (json-parse-string request-body :object-type 'alist))
               "/srv/movie.mp4")))))

(ert-deftest rvid-play-keeps-video-bytes-out-of-the-emacs-request-path ()
  (let* ((rvid--current-playback nil)
         (remote (rvid--remote-from-path
                  "/ssh:alice@example:/srv/movie.mp4"))
         (session
          (rbridge-session-create
           :remote remote :service (rvid--bridge-service) :state 'ready
           :local-port 55123 :metadata '(:auth-token "secret")))
         (registration
          (rvid-registration-create
           :id "cap" :name "movie.mp4" :size 100
           :url-path "/v1/media/cap/movie.mp4"))
         registered-path started-url)
    (cl-letf (((symbol-function 'rvid--validate-file) #'ignore)
              ((symbol-function 'rvid--validate-backend) #'ignore)
              ((symbol-function 'rvid--connect-remote)
               (lambda (_remote) session))
              ((symbol-function 'rbridge-remote-expanded-localname)
               (lambda (_remote path) path))
              ((symbol-function 'rvid--register-media)
               (lambda (_session path)
                 (setq registered-path path)
                 registration))
              ((symbol-function 'rvid--start-mpv)
               (lambda (called-session called-registration)
                 (setq started-url
                       (rvid--media-url called-session called-registration))
                 (rvid-playback-create
                  :backend 'mpv :session called-session
                  :registration called-registration))))
      (rvid-play "/ssh:alice@example:/srv/movie.mp4" 'mpv)
      (should (equal registered-path "/srv/movie.mp4"))
      (should (equal started-url
                     "http://127.0.0.1:55123/v1/media/cap/movie.mp4")))))

(ert-deftest rvid-auto-backend-prefers-mpv-and-falls-back-to-xwidget ()
  (cl-letf (((symbol-function 'rvid--mpv-available-p) (lambda () t))
            ((symbol-function 'rvid--xwidget-available-p) (lambda () nil)))
    (should (eq (rvid--resolve-backend 'auto) 'mpv)))
  (cl-letf (((symbol-function 'rvid--mpv-available-p) (lambda () nil))
            ((symbol-function 'rvid--xwidget-available-p) (lambda () t)))
    (should (eq (rvid--resolve-backend 'auto) 'xwidget))))

(ert-deftest rvid-rejects-a-directory-before-starting-a-session ()
  (let ((rvid--file-directory-p-function (lambda (_file) t)))
    (cl-letf (((symbol-function 'rvid--connect-remote)
               (lambda (_remote)
                 (ert-fail "must not connect for a directory"))))
      (should-error
       (rvid-play "/ssh:p44:/srv/videos" 'xwidget)
       :type 'user-error))))

(ert-deftest rvid-mpv-command-uses-capability-url-and-private-ipc-socket ()
  (let* ((runtime-root (make-temp-file "rvid-test-runtime-" t))
         (temporary-file-directory runtime-root)
         (remote (rvid--remote-from-path
                  "/ssh:alice@example:/srv/movie.mp4"))
         (session
          (rbridge-session-create
           :remote remote :service (rvid--bridge-service) :state 'dead
           :local-port 55123))
         (registration
          (rvid-registration-create
           :id "cap" :name "movie.mp4"
           :url-path "/v1/media/cap/movie.mp4"))
         (original-make-process (symbol-function 'make-process))
         captured-command playback)
    (unwind-protect
        (let ((rvid--make-process-function
               (lambda (&rest properties)
                 (setq captured-command (plist-get properties :command))
                 (funcall original-make-process
                          :name "rvid-test-player"
                          :command '("sh" "-c" "sleep 5")
                          :connection-type 'pipe
                          :noquery t))))
          (setq playback (rvid--start-mpv session registration))
          (should (member
                   "http://127.0.0.1:55123/v1/media/cap/movie.mp4"
                   captured-command))
          (should
           (seq-some
            (lambda (argument)
              (string-prefix-p "--input-ipc-server=" argument))
            captured-command)))
      (when (and playback
                 (process-live-p (rvid-playback-process playback)))
        (delete-process (rvid-playback-process playback)))
      (when (file-directory-p runtime-root)
        (delete-directory runtime-root t)))))

(ert-deftest rvid-e2e-bootstrap-registers-seekable-media ()
  :tags '(integration)
  (let ((remote-file (getenv "RVID_E2E_REMOTE_FILE")))
    (unless remote-file
      (ert-skip "RVID_E2E_REMOTE_FILE is not set"))
    (let* ((rvid--sessions (make-hash-table :test #'equal))
           (remote (rvid--remote-from-path remote-file))
           (session nil)
           (registration nil))
      (unwind-protect
          (progn
            (setq session (rvid--connect-remote remote))
            (should (alist-get 'media_range
                               (rbridge-session-capabilities session)))
            (setq registration
                  (rvid--register-media
                   session
                   (rbridge-remote-expanded-localname
                    remote (rbridge-remote-localname remote))))
            (let* ((url-proxy-services nil)
                   (url-request-method "GET")
                   (url-request-extra-headers '(("Range" . "bytes=0-0")))
                   (buffer
                    (url-retrieve-synchronously
                     (rvid--media-url session registration) t t 10)))
              (should buffer)
              (unwind-protect
                  (with-current-buffer buffer
                    (let ((body-start (rvid--response-body-start)))
                      (should (= url-http-response-status 206))
                      (should (= (- (point-max) body-start) 1))))
                (kill-buffer buffer))))
        (when (and session registration)
          (rvid--revoke-registration session registration))
        (when session
          (rbridge-disconnect-session session))))))

(provide 'rvid-test)

;;; rvid-test.el ends here
