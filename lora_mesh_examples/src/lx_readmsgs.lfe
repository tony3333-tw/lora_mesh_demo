;;;
;;; Print every message as it arrives, like tcp_mchome_readmsgs.py and
;;; chan_recv_with_path.py. The LFE twin of ex_readmsgs.erl.
;;;
;;;   lme readmsgs --lfe
;;;   lme readmsgs --lfe --count 5
;;;

(defmodule lx_readmsgs
  (export (run 1)))

(defun run (opts)
  (let* ((client (lmc:connect opts))
         (names (lmc:names (lmc:nodes client 500))))
    (lmc:subscribe client 'rx)
    (io:format "Waiting for messages (Ctrl-C to stop)...~n")
    (loop client names (maps:get 'count opts 'infinity))
    (lmc:disconnect client)))

(defun loop
  ((_client _names 0)
   'ok)
  ((client names count)
   (case (lmc:next client 'infinity)
     ((tuple 'rx rx)
      (io:format "~ts~n" (list (lmc:describe rx names)))
      (loop client names (decrement count)))
     ((tuple 'node node)
      ;; keep names current: a new node may speak next
      (loop client (lmc:add_name names node) count)))))

(defun decrement
  (('infinity) 'infinity)
  ((n) (- n 1)))
