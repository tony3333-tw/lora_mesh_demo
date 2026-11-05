;;;
;;; Trace the route to a node, like send-traceroute-simple.py and
;;; print-traceroute.py. The LFE twin of mte_traceroute.erl.
;;;
;;;   mte traceroute --lfe -d "Hill top"
;;;   mte traceroute --lfe -d '!60c0ffee' --hop-limit 5
;;;
;;; Radios limit traceroutes (about one per 30 s).
;;;

(defmodule mtl_traceroute
  (export (run 1)))

(defun unknown-snr () -128)

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (dest (mtc:dest c opts))
         (hop-limit (maps:get 'hop_limit opts 3)))
    (io:format "Sending traceroute request to ~ts (hop limit ~p), this can take a while...~n"
               (list (mtc:name c dest) hop-limit))
    (let ((id (mtc:send_traceroute c dest hop-limit)))
      (case (mtc:reply c id 'TRACEROUTE_APP (* 30000 (+ hop-limit 1)))
        ((tuple 'ok p)
         (print-route c p))
        ((tuple 'error reason)
         (io:format "Traceroute failed: ~s~n" (list reason)))
        ('timeout
         (io:format "Timed out waiting for traceroute~n"))
        ('closed
         (io:format "the radio closed the connection~n"))))
    (mtc:close c)))

;; p comes from the destination (from) to us (to)
(defun print-route (c p)
  (let* ((from (maps:get 'from p))
         (to (maps:get 'to p))
         (route (mtc:get p '(decoded traceroute) (map)))
         (towards (maps:get 'route route '()))
         (back (maps:get 'route_back route '()))
         (snr-back (maps:get 'snr_back route '())))
    (io:format "Route traced towards destination:~n")
    (io:format "~ts~n" (list (route-line c
                                         (++ (cons to towards) (list from))
                                         (maps:get 'snr_towards route '()))))
    ;; only valid with hop_start and one SNR per hop plus the last one
    (if (andalso (maps:is_key 'hop_start p)
                 (=:= (length snr-back) (+ (length back) 1)))
      (progn
        (io:format "Route traced back to us:~n")
        (io:format "~ts~n" (list (route-line c
                                             (++ (cons from back) (list to))
                                             snr-back)))))))

;; (first . hops): each hop with the SNR it was heard at (dB * 4)
(defun route-line (c nodes snrs)
  (let* ((hops (tl nodes))
         (valid (=:= (length snrs) (length hops))))
    (cons (mtc:name c (hd nodes))
          (lists:map
           (lambda (step)
             (let ((i (element 1 step))
                   (node (element 2 step)))
               (list " --> " (mtc:name c node) " (" (snr valid snrs i) "dB)")))
           (lists:enumerate hops)))))

(defun snr
  (('true snrs i)
   (let ((snr (lists:nth i snrs)))
     (if (=:= snr (unknown-snr))
       "?"
       (float_to_list (/ snr 4) '(short)))))
  (('false _snrs _i)
   "?"))
