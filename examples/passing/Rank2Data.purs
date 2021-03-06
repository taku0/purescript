module Rank2Data where

  data Id = Id forall a. a -> a

  runId = \id a -> case id of
    Id f -> f a

  data Nat = Nat forall r. r -> (r -> r) -> r

  runNat = \nat -> case nat of
    Nat f -> f 0 (\n -> n + 1)

  zero = Nat (\zero _ -> zero)

  succ = \n -> case n of
    Nat f -> Nat (\zero succ -> succ (f zero succ))

  add = \n m -> case n of
    Nat f -> case m of
      Nat g -> Nat (\zero succ -> g (f zero succ) succ)

  one = succ zero
  two = succ zero
  four = add two two
  fourNumber = runNat four
    
module Main where

main = Trace.trace "Done"
