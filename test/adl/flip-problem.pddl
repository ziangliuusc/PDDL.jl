;; Grid flipping problem
(define (problem flip-problem)
  (:domain flip)
  (:objects r1 r2 r3 - row c1 c2 c3 - column)
  (:init (white r1 c2)
         (white r2 c1)
         (white r2 c3)
         (white r3 c2))
  (:goal (forall (?r - row ?c - column) (white ?r ?c)))
)
