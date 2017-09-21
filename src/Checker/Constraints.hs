{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{- Deals with compilation of coeffects into symbolic representations of SBV -}

module Checker.Constraints where

import Data.Foldable (foldrM)
import Data.SBV hiding (kindOf, name, symbolic)
import qualified Data.Set as S
import GHC.Generics (Generic)

import Context             (Env)
import Syntax.Expr
import Syntax.Pretty
import Syntax.FirstParameter

-- Represent constraints generated by the type checking algorithm
data Constraint =
    Eq  Span Coeffect Coeffect CKind
  | Leq Span Coeffect Coeffect CKind
  deriving (Show, Generic)

instance FirstParameter Constraint Span

-- Used to negate constraints
data Neg a = Neg a
  deriving Show

instance Pretty (Neg Constraint) where
    pretty (Neg (Eq _ c1 c2 _))  = pretty c1 ++ " != " ++ pretty c2
    pretty (Neg (Leq _ c1 c2 (CConstr "Nat="))) = pretty c1 ++ " is not equal to " ++ pretty c2
    pretty (Neg (Leq _ c1 c2 _)) = pretty c1 ++ " > " ++ pretty c2

instance Pretty Constraint where
    pretty (Eq _ c1 c2 _)  = pretty c1 ++ " == " ++ pretty c2
    pretty (Leq _ c1 c2 _) = pretty c1 ++ " <= " ++ pretty c2


normaliseConstraint :: Constraint -> Constraint
normaliseConstraint (Eq s c1 c2 k)   = Eq s (normalise c1) (normalise c2) k
normaliseConstraint (Leq s c1 c2 k) = Leq s (normalise c1) (normalise c2) k

-- Map from Ids to symbolic integer variables in the solver
type SolverVars  = [(Id, SCoeffect)]

-- Compile constraint into an SBV symbolic bool, along with a list of
-- constraints which are trivially unsatisfiable (e.g., things like 1=0).
compileToSBV :: [Constraint] -> Env CKind -> Env CKind
             -> (Symbolic SBool, [Constraint])
compileToSBV constraints cenv cVarEnv = (do
    (preds, solverVars) <- foldrM createFreshVar (true, []) cenv
    let preds' = foldr ((&&&) . compile solverVars) true constraints'
    return (preds &&& preds'), trivialUnsatisfiableConstraints constraints')
  where
    constraints' = rewriteConstraints cVarEnv constraints
    -- Create a fresh solver variable of the right kind and
    -- with an associated refinement predicate
    createFreshVar
      :: (Id, CKind) -> (SBool, SolverVars) -> Symbolic (SBool, SolverVars)
    createFreshVar (var, kind) (preds, env) = do
      (pre, symbolic) <- freshCVar var kind
      return (pre &&& preds, (var, symbolic) : env)

-- given an environment mapping coeffect type variables to coeffect typ,
-- then rewrite a set of constraints so that any occruences of the kind variable
-- are replaced with the coeffect type
rewriteConstraints :: Env CKind -> [Constraint] -> [Constraint]
rewriteConstraints env =
    map (\c -> foldr (\(var, kind) -> updateConstraint var kind) c env)
  where
    -- `updateConstraint v k c` rewrites any occurence of the kind variable
    -- `v` in the constraint `c` with the kind `k`
    updateConstraint :: Id -> CKind -> Constraint -> Constraint
    updateConstraint ckindVar ckind (Eq s c1 c2 k) =
      Eq s (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
        (case k of
          CPoly ckindVar' | ckindVar == ckindVar' -> ckind
          _ -> k)
    updateConstraint ckindVar ckind (Leq s c1 c2 k) =
      Leq s (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
        (case k of
          CPoly ckindVar' | ckindVar == ckindVar' -> ckind
          _  -> k)

    -- `updateCoeffect v k c` rewrites any occurence of the kind variable
    -- `v` in the coeffect `c` with the kind `k`
    updateCoeffect :: Id -> CKind -> Coeffect -> Coeffect
    updateCoeffect ckindVar ckind (CZero (CPoly ckindVar'))
      | ckindVar == ckindVar' = CZero ckind
    updateCoeffect ckindVar ckind (COne (CPoly ckindVar'))
      | ckindVar == ckindVar' = COne ckind
    updateCoeffect ckindVar ckind (CPlus c1 c2) =
      CPlus (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect ckindVar ckind (CTimes c1 c2) =
      CTimes (updateCoeffect ckindVar ckind c1) (updateCoeffect ckindVar ckind c2)
    updateCoeffect _ _ c = c

-- Symbolic coeffects
data SCoeffect =
     SNat   NatModifier SInteger
   | SNatOmega SInteger
   | SFloat  SFloat
   | SLevel SInteger
   | SSet   (S.Set (Id, Type))
  deriving (Show, Eq)

-- | Generate a solver variable of a particular kind, along with
-- a refinement predicate
freshCVar :: Id -> CKind -> Symbolic (SBool, SCoeffect)

freshCVar name (CConstr "Nat*") = do
  solverVar <- exists name
  return (solverVar .>= literal 0, SNatOmega solverVar)

freshCVar name (CConstr "Nat") = do
  solverVar <- exists name
  return (solverVar .>= literal 0, SNat Ordered solverVar)
freshCVar name (CConstr "Nat=") = do
  solverVar <- exists name
  return (solverVar .>= literal 0, SNat Discrete solverVar)
freshCVar name (CConstr "Q") = do
  solverVar <- exists name
  return (true, SFloat solverVar)
freshCVar name (CConstr "Level") = do
  solverVar <- exists name
  return (solverVar .>= literal 0 &&& solverVar .<= 1, SLevel solverVar)
freshCVar _ (CConstr "Set") = return (true, SSet S.empty)
freshCVar _ k =
  error $ "Trying to make a fresh solver variable for a coeffect of kind: " ++ show k ++ " but I don't know how."

-- Compile a constraint into a symbolic bool (SBV predicate)
compile :: SolverVars -> Constraint -> SBool
compile vars (Eq _ c1 c2 k) =
  eqConstraint c1' c2'
    where
      c1' = compileCoeffect c1 k vars
      c2' = compileCoeffect c2 k vars
compile vars (Leq _ c1 c2 k) =
  lteConstraint c1' c2'
    where
      c1' = compileCoeffect c1 k vars
      c2' = compileCoeffect c2 k vars

-- Compile a coeffect term into its symbolic representation
compileCoeffect :: Coeffect -> CKind -> [(Id, SCoeffect)] -> SCoeffect

compileCoeffect (Level n) (CConstr "Level") _ = SLevel . fromInteger . toInteger $ n

compileCoeffect (CNat Ordered n)  (CConstr "Nat") _
  = SNat Ordered  . fromInteger . toInteger $ n
compileCoeffect (CNat Discrete n)  (CConstr "Nat=") _
  = SNat Discrete  . fromInteger . toInteger $ n

compileCoeffect (CNatOmega (Left ())) (CConstr "Nat*") _
  = error "TODO: Recursion not yet supported"
  -- SNatOmega . fromInteger .
  --   allElse <- forall_

compileCoeffect (CNatOmega (Right n)) (CConstr "Nat*") _
  = SNatOmega . fromInteger . toInteger $ n

compileCoeffect (CFloat r) (CConstr "Q")     _ = SFloat  . fromRational $ r
compileCoeffect (CSet xs) (CConstr "Set")   _ = SSet   . S.fromList $ xs
compileCoeffect (CVar v) _ vars =
  case lookup v vars of
   Just cvar -> cvar
   Nothing   ->
    error $ "Looking up a variable '" ++ v ++ "' in " ++ show vars

compileCoeffect (CPlus n m) k@(CConstr "Set") vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SSet s, SSet t) -> SSet $ S.union s t
    (n', m') -> error $ "Trying to compileCoeffect: " ++ show n' ++ " + " ++ show m'

compileCoeffect (CPlus n m) k@(CConstr "Level") vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SLevel lev1, SLevel lev2) -> SLevel $ lev1 `smax` lev2
    (n', m') -> error $ "Trying to compileCoeffect: " ++ show n' ++ " + " ++ show m'

compileCoeffect (CPlus n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) | o1 == o2 -> SNat o1 (n1 + n2)
    (SFloat n1, SFloat n2) -> SFloat $ n1 + n2
    (n', m') -> error $ "Trying to compileCoeffect: " ++ show n' ++ " + " ++ show m'

compileCoeffect (CTimes n m) k@(CConstr "Set") vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SSet s, SSet t) -> SSet $ S.union s t
    (n', m') -> error $ "Trying to compileCoeffect: " ++ show n' ++ " + " ++ show m'

compileCoeffect (CTimes n m) k@(CConstr "Level") vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SLevel lev1, SLevel lev2) -> SLevel $ lev1 `smin` lev2
    (n', m') -> error $ "Trying to compileCoeffect: " ++ show n' ++ " * " ++ show m'

compileCoeffect (CTimes n m) k vars =
  case (compileCoeffect n k vars, compileCoeffect m k vars) of
    (SNat o1 n1, SNat o2 n2) | o1 == o2 -> SNat o1 (n1 * n2)
    (SFloat n1, SFloat n2) -> SFloat $ n1 * n2
    (m', n') -> error $ "Trying to compileCoeffect solver contraints for: "
                      ++ show m' ++ " * " ++ show n'

compileCoeffect (CZero (CConstr "Level")) (CConstr "Level") _ = SLevel 0
compileCoeffect (CZero (CConstr "Nat")) (CConstr "Nat")     _ = SNat Ordered 0
compileCoeffect (CZero (CConstr "Nat=")) (CConstr "Nat=")   _ = SNat Discrete 0
compileCoeffect (CZero (CConstr "Q"))  (CConstr "Q")        _ = SFloat (fromRational 0)
compileCoeffect (CZero (CConstr "Set")) (CConstr "Set")     _ = SSet (S.fromList [])

compileCoeffect (COne (CConstr "Level")) (CConstr "Level") _ = SLevel 1
compileCoeffect (COne (CConstr "Nat")) (CConstr "Nat")     _ = SNat Ordered 1
compileCoeffect (COne (CConstr "Nat=")) (CConstr "Nat=")   _ = SNat Discrete 1
compileCoeffect (COne (CConstr "Q")) (CConstr "Q")         _ = SFloat (fromRational 1)
compileCoeffect (COne (CConstr "Set")) (CConstr "Set")     _ = SSet (S.fromList [])

compileCoeffect c (CPoly _) _ =
   error $ "Trying to compile a polymorphically kinded " ++ pretty c

compileCoeffect coeff ckind _ =
   error $ "Can't compile a coeffect: " ++ pretty coeff
        ++ " of kind " ++ pretty ckind

-- | Generate equality constraints for two symbolic coeffects
eqConstraint :: SCoeffect -> SCoeffect -> SBool
eqConstraint (SNat _ n) (SNat _ m) = n .== m
eqConstraint (SFloat n) (SFloat m)   = n .== m
eqConstraint (SLevel l) (SLevel k) = l .== k
eqConstraint x y =
   error $ "Kind error trying to generate equality " ++ show x ++ " = " ++ show y

-- | Generate less-than-equal constraints for two symbolic coeffects
lteConstraint :: SCoeffect -> SCoeffect -> SBool
lteConstraint (SNat Ordered n) (SNat Ordered m)   = n .<= m
lteConstraint (SNat Discrete n) (SNat Discrete m) = n .== m
lteConstraint (SFloat n) (SFloat m)   = n .<= m
lteConstraint (SLevel l) (SLevel k) = l .== k
lteConstraint (SSet s) (SSet t) =
  if s == t then true else false
lteConstraint x y =
   error $ "Kind error trying to generate " ++ show x ++ " <= " ++ show y


trivialUnsatisfiableConstraints :: [Constraint] -> [Constraint]
trivialUnsatisfiableConstraints cs = filter unsat (map normaliseConstraint cs)
  where
    unsat :: Constraint -> Bool
    unsat (Eq _ c1 c2 _)  = c1 /= c2
    unsat (Leq _ c1 c2 _) = not (c1 `leqC` c2)

    -- Attempt to see if one coeffect is trivially less than the other
    leqC :: Coeffect -> Coeffect -> Bool
    leqC (CNat Ordered n)  (CNat Ordered m)  = n <= m
    leqC (CNat Discrete n) (CNat Discrete m) = n == m
    leqC (Level n) (Level m)   = n <= m
    leqC (CFloat n) (CFloat m) = n <= m
    leqC _ _                   = True