;;;
;;; Stay connected to a radio, like tcp_watchdog.py: every --every
;;; seconds (10) ask it for its firmware version, connect again when
;;; that fails. The LFE twin of mte_watchdog.erl.
;;;
;;;   mte watchdog --lfe --host 192.168.1.42
;;;

(defmodule mtl_watchdog
  (export (run 1)))

(defun retry-ms () 3000)

(defun run (opts)
  (let ((every (* (maps:get 'every opts 10) 1000)))
    (loop (connect opts) opts every (mtc:deadline every))))

(defun connect (opts)
  (try
    (let ((c (mtc:connect opts)))
      (io:format "Interface initialized.~n")
      c)
    (catch
      ((tuple 'error (tuple 'radio_connect reason) _)
       (io:format "Failed to initialize interface: ~p~n" (list reason))
       'undefined))))

;; no connection: try again after a while
(defun loop
  (('undefined opts every _check)
   (io:format "Retrying connection to the interface...~n")
   (timer:sleep (retry-ms))
   (loop (connect opts) opts every (mtc:deadline every)))
  ((c opts every check)
   (case (mtc:next c (mtc:left check))
     ((tuple 'packet (= (map 'decoded (map 'portnum 'TEXT_MESSAGE_APP)) p))
      (io:format "~p~n" (list p))
      (loop c opts every check))
     ((tuple 'packet _other)
      (loop c opts every check))
     ('closed
      (io:format "Error with the interface: closed, reconnecting~n")
      (loop 'undefined opts every check))
     ('timeout
      (io:format "Checking interface connection...~n")
      (case (firmware c)
        ((tuple 'ok version)
         (io:format "Firmware Version: ~ts~nInterface is connected.~n" (list version))
         (loop c opts every (mtc:deadline every)))
        ((tuple 'error reason)
         (io:format "Error with the interface (~p), reconnecting~n" (list reason))
         (mtc:close c)
         (loop 'undefined opts every check)))))))

;; node.getMetadata(): an admin request to our own radio
(defun firmware (c)
  (try
    (let ((id (mtc:admin c (map 'get_device_metadata_request 'true))))
      (case (mtc:reply c id 'ADMIN_APP 5000)
        ((tuple 'ok p)
         (tuple 'ok (mtc:get p
                             '(decoded admin get_device_metadata_response firmware_version)
                             #"?")))
        (other
         (tuple 'error other))))
    (catch
      ((tuple 'error reason _)
       (tuple 'error reason)))))
