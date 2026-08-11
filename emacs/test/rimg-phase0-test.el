;;; rimg-phase0-test.el --- Image-Dired integration spike -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'dired)
(require 'ert)
(require 'image-dired)
(require 'image-dired-tags)
(require 'tramp)

(defconst rimg-phase0-test-remote-original
  (getenv "RIMG_PHASE0_REMOTE_ORIGINAL")
  "Opt-in TRAMP image fixture used by the real-host integration test.")

(defvar rimg-phase0-test--tramp-operations nil)

(defun rimg-phase0-test--record-tramp-operation (function operation &rest args)
  "Record OPERATION before calling TRAMP file handler FUNCTION with ARGS."
  (push operation rimg-phase0-test--tramp-operations)
  (apply function operation args))

(defun rimg-phase0-test--dired-mark-at-file (buffer file)
  "Return the Dired mark character for FILE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (should (dired-goto-file file))
      (char-after (line-beginning-position)))))

(ert-deftest rimg-phase0-local-thumb-retains-remote-original ()
  "Verify the stock Image-Dired insertion seam with a real TRAMP original."
  (let* ((remote-original
          (or rimg-phase0-test-remote-original
              (ert-skip "RIMG_PHASE0_REMOTE_ORIGINAL is not set")))
         (remote-directory (file-name-directory remote-original))
         (thumb-file (or (getenv "RIMG_PHASE0_THUMB")
                         (ert-skip "RIMG_PHASE0_THUMB is not set")))
         (temp-root (make-temp-file "rimg-phase0-emacs-" t))
         (image-dired-dir (expand-file-name "image-dired/" temp-root))
         (image-dired-tags-db-file
          (expand-file-name "tags.db" image-dired-dir))
         (image-dired-thumbnail-buffer "*rimg-phase0-thumbnails*")
         (image-dired-marking-shows-next nil)
         (dired-buffer nil)
         (thumbnail-buffer nil)
         (displayed-file nil)
         (rimg-phase0-test--tramp-operations nil)
         (started-at (float-time))
         (insertion-seconds nil))
    (unwind-protect
        (progn
          (should (file-exists-p thumb-file))
          (setq dired-buffer (dired-noselect remote-directory))
          (with-current-buffer dired-buffer
            (should (dired-goto-file remote-original)))

          (setq thumbnail-buffer (image-dired-create-thumbnail-buffer))
          (with-current-buffer thumbnail-buffer
            (let ((inhibit-read-only t)
                  (default-directory temp-root))
              (erase-buffer)
              (advice-add 'tramp-file-name-handler :around
                          #'rimg-phase0-test--record-tramp-operation)
              (unwind-protect
                  (let ((insertion-started-at (float-time)))
                    (image-dired-insert-thumbnail
                     thumb-file remote-original dired-buffer)
                    (setq insertion-seconds
                          (- (float-time) insertion-started-at)))
                (advice-remove 'tramp-file-name-handler
                               #'rimg-phase0-test--record-tramp-operation))
              (goto-char (point-min))
              (should (image-dired-image-at-point-p))
              (should (equal (image-dired-original-file-name)
                             remote-original))
              (should (eq (image-dired-associated-dired-buffer) dired-buffer))
              ;; Current Image-Dired represents an empty tag set as ("").
              (should (equal (get-text-property (point) 'tags) '("")))
              (should (equal (get-text-property (point) 'comment) nil))

              (cl-letf (((symbol-function 'image-dired-display-image)
                         (lambda (file &optional _ignored)
                           (setq displayed-file file))))
                (image-dired-display-this))
              (should (equal displayed-file remote-original))

              (image-dired-mark-thumb-original-file)
              (should (eq (rimg-phase0-test--dired-mark-at-file
                           dired-buffer remote-original)
                          ?*))
              (goto-char (point-min))
              (image-dired-unmark-thumb-original-file)
              (should (eq (rimg-phase0-test--dired-mark-at-file
                           dired-buffer remote-original)
                          ?\s))))

          (should-not rimg-phase0-test--tramp-operations)
          (princ
           (format
            (concat "RIMG_PHASE0 insertion_seconds=%.6f total_seconds=%.6f "
                    "tramp_operations=%S original=%s\n")
            insertion-seconds
            (- (float-time) started-at)
            (nreverse rimg-phase0-test--tramp-operations)
            remote-original)))
      (when (buffer-live-p thumbnail-buffer)
        (kill-buffer thumbnail-buffer))
      (when (buffer-live-p dired-buffer)
        (kill-buffer dired-buffer))
      (delete-directory temp-root t))))

(provide 'rimg-phase0-test)

;;; rimg-phase0-test.el ends here
