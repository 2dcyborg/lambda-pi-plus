
module ConstraintBased (checker) where

import Prelude hiding (print)

--import Data.List

import qualified Data.Map as Map

import qualified Data.Maybe as Maybe

import Text.PrettyPrint.HughesPJ hiding (parens, ($$))

import qualified Unbound.Generics.LocallyNameless as LN

import Common

import Constraint hiding (cToUnifForm, iToUnifForm)

import qualified Data.List as List

import qualified PatternUnify.Tm as Tm


--import Debug.Trace (trace)

--import qualified Solver

mapSnd f (a,b) = (a, f b)
mapFst f (a,b) = (f a, b)


--errorMsg :: [(Region, String)] -> String
--errorMsg pairs =
--  List.intercalate "\n" $
--  map (\(reg, err) -> show reg ++ ": " ++ err ) pairs

checker :: TypeChecker
checker (valNameEnv, typeContext) term =
  let
    toPos (reg, err) = case reg of
      BuiltinRegion -> (Nothing, err)
      (SourceRegion pos) -> (Just pos, err)
    (typeGlobals, typeLocals) = splitContext typeContext
    (valGlobals, valLocals) = splitContext  valNameEnv
    genResult =  getConstraints (WholeEnv valLocals typeLocals valGlobals typeGlobals) term
    soln = solveConstraintM genResult
    -- solvedString = case solvedMetas of
    --   Left _ -> ""
    --   Right pairs ->
    --     "Solved metas:\n"
    --     ++ (intercalate "\n" (map (\(s, v) -> s ++ " := " ++ Tm.prettyString v) pairs))
  in
    case soln of
      Left pairs -> Left $ map toPos pairs
      Right (tp, nf, subs, metaLocs) -> Right $
        let
          subbedVal = LN.runFreshM $ Tm.eval subs nf
          pairToMaybe (nm, val) = do
            loc <- Map.lookup nm metaLocs
            return (loc, val)
          namePairs = Maybe.catMaybes $ map pairToMaybe $ Map.toList subs
        in
          (tp, subbedVal, namePairs)


conStar = Tm.SET

getConstraints :: WholeEnv -> ITerm_ -> ConstraintM (Tm.Nom, Tm.VAL)
--getConstraints env term | trace ("\n\n**************************************\nChecking, converted " ++ show (iPrint_ 0 0 term))  $ trace ("\n  into " ++ Tm.prettyString (constrEval (map (mapFst Global) $ globalTypes env, map (mapFst Global) $ globalValues env) term ) ++ "\n\n") False
--  = error "genConstraints"
getConstraints env term =
  do
    finalType <- iType0_ env term
    finalVar <- freshTopLevel Tm.SET
    finalValue <- evaluate 0 (L startRegion $ Inf_ term) env
    unifySets startRegion finalType (Tm.meta finalVar) env
    return (finalVar, finalValue)

iType0_ :: WholeEnv -> ITerm_ -> ConstraintM ConType
iType0_ = iType_ 0

iType_ :: Int -> WholeEnv -> ITerm_ -> ConstraintM ConType
iType_ iiGlobal g lit@(L reg it) = --trace ("ITYPE " ++ show (iPrint_ 0 0 lit)) $
  do
    result <- iType_' iiGlobal g it
    return $ --trace ("===>  RET ITYPE " ++ show (iPrint_ 0 0 lit) ++ " :: " ++ Tm.prettyString result) $
      result
  where
    iType_' ii g m@(Meta_ s) = do
      metaType <- freshType reg g
      ourNom <- return $ LN.s2n s --freshNom s
      recordSourceMeta reg ourNom
      --Add metavariable to our context, and return its type
      _ <- declareWithNom reg g metaType ourNom
      return metaType

    iType_' ii g (Ann_ e tyt )
      =
        do
          cType_  ii g tyt conStar
          ty <- evaluate ii tyt g
          --trace ("&&" ++ show ii ++ "Annotated " ++ show e ++ " as " ++ show ty)  $
          cType_ ii g e ty
          return ty
    iType_' ii g Star_
       =  return conStar
    iType_' ii g (Pi_ tyt tyt')
       =  do  cType_ ii g tyt conStar
              argNom <- freshNom $ localName (ii)
              ty <- evaluate ii tyt g --Ensure LHS has type Set
              --Ensure, when we apply free var to RHS, we get a set
              let newEnv = addType (ii, ty) $ addValue (ii, Tm.var argNom)  g
              cType_  (ii + 1) newEnv
                        (cSubst_ 0 (builtin $ Free_ (Local ii)) tyt') conStar
              return conStar
    --Similar to Pi
    iType_' ii g (Sigma_ tyt tyt')
       =  do  cType_ ii g tyt conStar
              argNom <- freshNom $ localName (ii)
              ty <- evaluate ii tyt g --Ensure LHS has type Set
              --Ensure, when we apply free var to RHS, we get a set
              let newEnv = addType (ii, ty) $ addValue (ii, Tm.var argNom)  g
              cType_  (ii + 1) newEnv
                        (cSubst_ 0 (builtin $ Free_ (Local ii)) tyt') conStar
              return conStar

    iType_' ii g (Free_ x)
      =     case typeLookup x g of
              Just ty        ->  return ty
              Nothing        ->  unknownIdent reg g (render (iPrint_ 0 0 (builtin $ Free_ x)))
    iType_' ii g (funExp :$: argExp)
      =     do
                fnType <- iType_ ii g funExp
                piArg <- freshType (region argExp) g
                piBodyFn <- fresh (region funExp) g (piArg Tm.--> Tm.SET) --TODO star to star?

                --trace ("APP " ++ show (iPrint_ 0 0 lit) ++ "\n  fn type, unifying " ++ Tm.prettyString fnType ++ "  WITH  " ++ Tm.prettyString (Tm.PI piArg piBodyFn)) $
                unifySets reg (fnType) (Tm.PI piArg piBodyFn) g

                --Ensure that the argument has the proper type
                cType_ ii g argExp piArg

                --Get a type for the evaluation of the argument
                argVal <- evaluate ii argExp g

                --Our resulting type is the application of our arg type into the
                --body of the pi type
                retType <- piBodyFn Tm.$$ argVal
                --trace ("APP " ++ show (iPrint_ 0 0 lit) ++ "\n  return " ++ Tm.prettyString retType) $
                return retType

    iType_' ii g Nat_                  =  return conStar
    iType_' ii g (NatElim_ m mz ms n)  =
      do  cType_ ii g m (Tm.Nat Tm.--> Tm.SET)
          --evaluate ii $ our param m
          mVal <- evaluate ii m g
          --Check that mz has type (m 0)
          ourApp1 <- (mVal Tm.$$ Tm.Zero)
          cType_ ii g mz ourApp1
          --Check that ms has type ( (k: N) -> m k -> m (S k) )
          ln <- freshNom $ "l"
          let lv = Tm.var ln
          ourApp2 <- (Tm.msVType mVal)
          cType_ ii g ms ourApp2
          --Make sure the number param is a nat
          cType_ ii g n Tm.Nat

          --We infer that our final expression has type (m n)
          nVal <- evaluate ii n g
          mVal Tm.$$ nVal

    iType_' ii g (Fin_ n) = do
      cType_ ii g n Tm.Nat
      return Tm.SET

    iType_' ii g (FinElim_ m mz ms n f) = do
      mVal <- evaluate ii m g
      --mzVal <- evaluate ii m g
      --msVal <- evaluate ii m g
      nVal <- evaluate ii n g
      fVal <- evaluate ii f g
      cType_ ii g m (Tm.finmType)
      cType_ ii g mz =<< (Tm.finmzVType mVal)
      cType_ ii g ms =<< (Tm.finmsVType mVal)
      cType_ ii g n (Tm.Nat)
      cType_ ii g f (Tm.Fin nVal)
      mVal Tm.$$$ [nVal, fVal]

    iType_' ii g (Vec_ a n) =
      do  cType_ ii g a  conStar
          cType_ ii g n  Tm.Nat
          return conStar
    iType_' ii g (VecElim_ a m mn mc n vs) =

      do  cType_ ii g a conStar
          aVal <- evaluate ii a g
          mVal <- evaluate ii m g
          nVal <- evaluate ii n g

          mType <- Tm.vmVType aVal
          cType_ ii g m mType

          mnType <- Tm.mnVType aVal mVal
          cType_ ii g mn mnType

          mcType <- Tm.mcVType aVal mVal
          cType_ ii g mc mcType

          cType_ ii g n $ Tm.Nat

          cType_ ii g vs ((Tm.Vec aVal nVal ))
          vsVal <- evaluate ii vs g

          Tm.vResultVType mVal nVal vsVal


    iType_' ii g (Eq_ a x y) =
      do  cType_ ii g a conStar
          aVal <- evaluate ii a g
          cType_ ii g x aVal
          cType_ ii g y aVal
          return conStar
    iType_' ii g (EqElim_ a m mr x y eq) =
      do
          --Our a value should be a type
          cType_ ii g a conStar
          --evaluate ii $ our a value
          aVal <- evaluate ii a g
          cType_ ii g m
            (mkPiFn aVal (\ x ->
             mkPiFn aVal ( \ y ->
             mkPiFn ((  Tm.Eq aVal x y)) ( \ _ -> conStar))))
          --evaluate ii $ our given m value
          mVal <- evaluate ii m g
          cType_ ii g mr =<<
            (mkPiFnM aVal ( \ x ->
             (  mVal Tm.$$$ [x, x] )))
          cType_ ii g x aVal
          xVal <- evaluate ii x g
          cType_ ii g y aVal
          yVal <- evaluate ii y g
          let
            eqC =
              ((Tm.Eq yVal xVal aVal))
          cType_ ii g eq eqC
          eqVal <- evaluate ii eq g
          (mVal Tm.$$$ [xVal, yVal])

    iType_' ii g (Fst_ pr) = do
      pairType <- iType_ ii g pr
      sType <- freshType (region pr) g
      tType <- fresh (region pr) g (sType Tm.--> conStar)
      unifySets reg pairType (Tm.SIG sType tType) g
      --Head has the type of the first elem
      return sType

    iType_' ii g (Snd_ pr) = do
      pairType <- iType_ ii g pr
      sType <- freshType (region pr) g
      tType <- fresh (region pr) g (sType Tm.--> conStar)
      unifySets reg pairType (Tm.SIG sType tType) g
      prVal <- evaluate ii (L reg $ Inf_ pr) g
      headVal <- prVal Tm.%% Tm.Hd
      --Head has second type, with first val given as argument
      tType Tm.$$ headVal


    iType_' ii g (Bound_ vi) = error "TODO why never bound?"
      --return $ (snd $ snd g `listLookup` (ii - (vi+1) ) ) --TODO is this right?


cType_ :: Int -> WholeEnv -> CTerm_ -> ConType -> ConstraintM ()
cType_ iiGlobal g lct@(L reg ct) globalTy = --trace ("CTYPE " ++ show (cPrint_ 0 0 lct) ++ " :: " ++ Tm.prettyString globalTy) $
  cType_' iiGlobal g ct globalTy
  where
    cType_' ii g (Inf_ e) tyAnnot
          =
            do
              tyInferred <- iType_ ii g e
              --Ensure that the annotation type and our inferred type unify
              --We have to evaluate ii $ our normal form
              --trace ("INF " ++ show e ++ "\nunifying " ++ show [tyAnnot, tyInferred] ++ "\nenv " ++ show g) $
              unifySets reg tyAnnot tyInferred g

    --Special case when we have metavariable in type
    cType_' ii g (Lam_ body) fnTy = do
        argTy <- freshType reg g
        argName <- freshNom $ localName (ii) --TODO ii or 0?
        --Our return type should be a function, from input type to set
        let newEnv = -- trace ("Lambda newEnv " ++ show ii ++ " old " ++ show g) $
              addValue (ii, Tm.var argName) $ addType (ii, argTy ) g
        returnTyFn <- fresh (region body) g (argTy Tm.--> conStar)
        let arg = -- trace ("Lambda giving arg " ++ show ii) $
              builtin $ Free_ (Local ii)
            --TODO g or newEnv?
        argVal <- return $ Tm.var argName --evalInEnv g $ Tm.var argName --iToUnifForm ii newEnv arg
        unifySets reg fnTy (Tm.PI argTy returnTyFn)  g
        returnTy <- freshType (region body) newEnv
        appedTy <- (returnTyFn Tm.$$ argVal)
        unifySets reg returnTy appedTy newEnv
        --unify  returnTyFn (Tm.lam argName returnTy) (argTy Tm.--> conStar) g --TODO is argVal good?
        --Convert bound instances of our variable into free ones
        let subbedBody = cSubst_ 0 arg body
        cType_  (ii + 1) newEnv subbedBody returnTy

    cType_' ii g (Pair_ x y) sigTy = do
      sType <- freshType (region x) g
      tType <- fresh (region y) g (sType Tm.--> conStar)
      unifySets reg sigTy (Tm.SIG sType tType) g
      --Head has the type of the first elem
      cType_ ii g x sType
      --Tail type depends on given argument
      fstVal <- evaluate ii x g
      appedTy <- (tType Tm.$$ fstVal)
      cType_ ii g y appedTy

    cType_' ii g Zero_      ty  =  unifySets reg ty Tm.Nat g
    cType_' ii g (Succ_ k)  ty  = do
      unifySets reg ty Tm.Nat g
      cType_ ii g k Tm.Nat

    cType_' ii g (FZero_ f)      ty  =  do
      cType_ ii g f Tm.Nat
      fVal <- evaluate ii f g
      unifySets reg ty (Tm.Fin fVal) g
    cType_' ii g (FSucc_ k f)  ty  = do
      cType_ ii g f Tm.Nat
      fVal <- evaluate ii f g
      unifySets reg ty (Tm.Fin fVal) g
      cType_ ii g k Tm.Nat

    cType_' ii g (Nil_ a) ty =
      do
          bVal <- freshType reg g
          unifySets reg ty (mkVec bVal Tm.Zero) g
          cType_ ii g a conStar
          aVal <- evaluate ii a g
          unifySets reg aVal bVal g
    cType_' ii g (Cons_ a n x xs) ty  =
      do  bVal <- freshType (region a) g
          k <- fresh (region n) g Tm.Nat
          --Trickery to get a Type_ to a ConType
          let kVal = Tm.Succ k
          unifySets reg ty (mkVec bVal kVal) g
          cType_ ii g a conStar

          aVal <- evaluate ii a g
          unifySets reg aVal bVal g

          cType_ ii g n Tm.Nat

          --Make sure our numbers match
          nVal <- evaluate ii n g
          unify reg nVal kVal Tm.Nat g

          --Make sure our new head has the right list type
          cType_ ii g x aVal
          --Make sure our tail has the right length
          cType_ ii g xs (mkVec bVal k)

    cType_' ii g (Refl_ a z) ty =
      do  bVal <- freshType (region a) g
          xVal <- fresh (region z) g bVal
          yVal <- fresh (region z) g bVal
          unifySets reg ty (mkEq bVal xVal yVal) g
          --Check that our type argument has kind *
          cType_ ii g a conStar
          --Get evaluation constraint for our type argument
          aVal <- evaluate ii a g

          --Check that our given type is the same as our inferred type --TODO is this right?
          unifySets reg aVal bVal g

          --Check that the value we're proving on has type A
          cType_ ii g z aVal

          --evaluate ii $ the value that we're proving equality on
          zVal <- evaluate ii z g

          --Show constraint that the type parameters must match that type
          unify reg zVal xVal bVal g
          unify reg zVal yVal bVal g
