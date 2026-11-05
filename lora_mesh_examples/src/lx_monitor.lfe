;;;
;;; Watch the mesh's nodes change, like pubsub_example.py and
;;; serial_battery_monitor.py. The LFE twin of ex_monitor.erl.
;;;
;;;   lme monitor --lfe
;;;

(defmodule lx_monitor
  (export (run 1)))

(defun run (opts)
  (let ((client (lmc:connect opts)))
    (lmc:subscribe client 'nodes)
    (io:format "Watching nodes (Ctrl-C to stop)...~n")
    (loop client #m())))

;; known: #m(id last-node-map)
(defun loop (client known)
  (receive
    ((tuple 'publish msg)
     (case (lmc:decode client msg)
       ((tuple 'node node)
        (let ((id (maps:get #"id" node)))
          (case (maps:find id known)
            ((tuple 'ok old)
             (changes old node))
            ('error
             (if (maps:get 'retain msg)
               (show "known  " node)
               (show "new node" node))))
          (loop client (maps:put id node known))))
       (_
        (loop client known))))))

(defun show (what node)
  (io:format "~s ~ts ~ts (~ts)~n"
             (list what (id node) (name node) (lmc:kind node))))

(defun changes (old new)
  (let ((name (name new)))
    (if (=/= (name old) name)
      (io:format "~ts: name ~ts -> ~ts~n" (list (id new) (name old) name)))
    (if (=/= (battery old) (battery new))
      (io:format "~ts: battery ~ts -> ~ts~n" (list name (battery old) (battery new))))
    (if (=/= (maps:get #"position" old) (maps:get #"position" new))
      (io:format "~ts: position ~ts~n" (list name (position new))))
    (heard name
           (maps:get #"heard_by" old #m())
           (maps:get #"heard_by" new #m()))))

;; a bridge that heard the node again (its "at" moved on)
(defun heard (name old-heard new-heard)
  (maps:foreach
   (lambda (bridge heard)
     (let ((at (maps:get #"at" heard))
           (rxq (maps:get #"rxq" heard)))
       (if (=/= (maps:get #"at" (maps:get bridge old-heard #m()) 'none) at)
         (io:format "~ts: heard by ~ts (SNR ~.1f, ~p hops)~n"
                    (list name
                          bridge
                          (float (maps:get #"rx_snr" rxq))
                          (- (maps:get #"hop_start" rxq)
                             (maps:get #"hop_limit" rxq)))))))
   new-heard))

(defun id (node)
  (maps:get #"id" node))

(defun name (node)
  (case (maps:get #"long_name" node 'null)
    ('null (id node))
    (name name)))

(defun battery (node)
  (case (maps:get #"battery_level" node 'null)
    ('null #"?")
    (101 #"powered")
    (level (iolist_to_binary (io_lib:format "~p%" (list level))))))

(defun position (node)
  (case (maps:get #"position" node 'null)
    ('null #"none")
    (pos (iolist_to_binary
          (io_lib:format "~.5f,~.5f"
                         (list (float (maps:get #"latitude" pos))
                               (float (maps:get #"longitude" pos))))))))
