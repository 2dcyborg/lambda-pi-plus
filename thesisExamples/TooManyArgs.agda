{-#  OPTIONS --type-in-type #-}
module TooManyArgs where

open import AgdaPrelude

myFun : (a : Set) -> a -> a -> a
myFun a x y = x

myApp = myFun _ Zero Zero Zero Zero
