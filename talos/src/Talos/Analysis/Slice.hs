{-# LANGUAGE GADTs, DataKinds, RankNTypes, PolyKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DefaultSignatures #-}

-- Path set analysis


module Talos.Analysis.Slice
  ( FInstId(..)
  , assertionsFID
  , SummaryClass(..), isAssertions, isResult, summaryClassToPreds, summaryClassFromPreds
  , CallNode(..), Slice(..)
  , Eqv(..), Merge(..)
  ) where

import           Data.Function (on)
import           Data.Map      (Map)
import qualified Data.Map      as Map
import           Data.Set      (Set)
import qualified Data.Set      as Set

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

import Daedalus.PP
import Daedalus.Panic

import Daedalus.Core
import Daedalus.Core.Free
import Daedalus.Core.TraverseUserTypes

import Talos.Analysis.SLExpr
-- import Debug.Trace

--------------------------------------------------------------------------------
-- Slices

-- This tags a particular instance of a function, It is used to name
-- SummaryClasses so that after analysis we can forget which AbsEnv
-- was used to generate the slices.
newtype FInstId = FInstId Int
  deriving (Eq, Ord, Generic, NFData)

-- We reserve a well-known id for the assertions class
assertionsFID :: FInstId
assertionsFID = FInstId 0

-- Grammars are summarised w.r.t a (pointed) collection of predicates
-- constraining the post-condition.  If the predicate is bottom then
-- we only care about the constraints inside the grammar.
data SummaryClass p = Assertions | Result (Set p)
  deriving (Ord, Eq, Show, Generic, NFData)

isAssertions, isResult :: SummaryClass p -> Bool
isAssertions Assertions = True
isAssertions _ = False

isResult = not . isAssertions

summaryClassToPreds :: SummaryClass p -> [p]
summaryClassToPreds Assertions = []
summaryClassToPreds (Result p) = Set.toList p

summaryClassFromPreds :: Ord p => [p] -> SummaryClass p
summaryClassFromPreds [] = Assertions
summaryClassFromPreds ps = Result (Set.fromList ps)

-- We represent a Call by a set of the entangled args.  If the
-- args aren't futher entangled by the calling context, then for
-- each argument slice we get a single Call node, where the Set is a
-- singleton containing the representative var as returned by
-- 'explodeDomain'.  The second argument tells us how to instantiate
-- the params used by the call.
--
-- We require a set so we can merge where the callers entangle params.
--
-- The first argument is whether this call is an assigned, in which
-- case the entangled vars must contain ResultVar.  Note that the
-- first argument can also be ResultVar, but that is the result of
-- the current function, not this call (e.g. def Foo = { ...; Bar })
--
-- Note that the set of entangled vars here is a bit different to
-- that which appears in a Domain, if only in intent --- these are
-- entangled by their context, while in a domain they are entangled
-- by use

-- def F x y = { Guard (x > 10); Guard (y > 10); ^ 42 }
--
-- def Q = { a = UInt8; z = F a a; Guard (z > 10); ^ true } -- entangles x and y above
--
-- F will generate slices for 'x', 'y', and the result, but at Q we
-- entangle 'x' and 'y' through 'a'

data CallNode cl =
  CallNode { callClass        :: cl
           , callName         :: FName
           -- ^ The called function
           , callSlices      :: Map Int [Maybe Name]
           -- ^ The slices that we use --- if the args are disjoint
           -- this will be a singleton map for this slice, but we
           -- might need to merge, hence we have multiple.  The map
           -- just allows us to merge easily.
           --           , callArgs        :: [Name]
           }
  deriving (Generic, NFData)

-- This is a variant of Grammar from Core
data Slice =
    SHole -- Type
  | SPure SLExpr
  --  | GetStream
  --  | SetStream Expr
  
  -- We only really care about a byteset.
  | SMatch ByteSet
  --  | Fail ErrorSource Type (Maybe Expr)
  | SDo Name Slice Slice
  --  | Let Name Expr Grammar
  | SChoice [Slice] -- This gives better probabilities than nested Ors
  | SCall (CallNode FInstId) 
  | SCase Bool (Case Slice)

  -- Extras for synthesis, we don't usually have SLExpr here as we
  -- don't slice the Exprs here.
  | SAssertion Expr -- FIXME: this is inferred from e.g. case x of True -> ...
  | SInverse Name Expr Expr
  -- ^ We have an inverse for this statement; this constructor has a
  -- name for the result (considered bound in this term only), the
  -- inverse expression, and a predicate constraining the value
  -- produced by this node (i.e., result of the original DDL code).
  deriving (Generic, NFData)

-- A note on inverses.  The ides is if we have something like
--
-- def F y = {
--   x = UInt8 # UInt8 # UInt8 # UInt 8
--   Guard (x > y && x < 1000)
--   ^ x
-- }
--
-- we can replace calls to F (in slices) like
--
-- ...
-- v = F y
-- ...
-- 
-- with (\result > y && \result < 1000) when synthesising, and then
-- [\result >> 24 as uint 8, \result >> 16 as uint 8, \result >> 8 as uint 8, \result as uint 8 ]
-- when constructing the path (i.e., when getting bytes).

--------------------------------------------------------------------------------
-- Domain Instances

-- This assumes the node came from the same statement (i.e., the paths
-- we are comparing are rooted at the same statement).  This means we
-- don't need to compare for equality.
--
-- Thus, for some cases, the presence of a node is enough to return
-- True (e.g. for Assertion)

class Eqv a where
  eqv :: a -> a -> Bool
  default eqv :: Eq a => a -> a -> Bool
  eqv = (==)

instance Eqv Int
instance Eqv Integer
instance Eqv FInstId
-- instance Eq p => Eqv (SummaryClass p) 
  -- eqv Assertions Assertions = True
  -- eqv (Result p) (Result q) = eqv p q
  -- eqv _          _          = False

-- instance Eqv SLExpr -- juse (==)

instance (Eqv a, Eqv b) => Eqv (a, b) where
  eqv (a, b) (a', b') = a `eqv` a' && b `eqv` b'

instance (Eqv a, Eqv b, Eqv c) => Eqv (a, b, c) where
  eqv (a, b, c) (a', b', c') = a `eqv` a' && b `eqv` b' && c `eqv` c'

instance Eqv a => Eqv [a] where
  eqv xs ys = and (zipWith eqv xs ys)

instance Eqv Slice where
  eqv l r =
    case (l, r) of
      (SHole {}, SHole {}) -> True
      (SHole {}, _)         -> False
      (_       , SHole {}) -> False
      
      (SPure e, SPure e')  -> eqv e e' -- FIXME: needed?
      (SMatch {}, SMatch {}) -> True
      (SDo _ l1 r1, SDo _ l2 r2)  -> (l1, r1) `eqv` (l2, r2)
      (SChoice ls, SChoice rs)       -> ls `eqv` rs
      (SCall lc, SCall rc)           -> lc `eqv` rc
      (SCase _ lc, SCase _ rc)       -> lc `eqv` rc
      (SAssertion {}, SAssertion {}) -> True      
      (SInverse {}, SInverse {})     -> True
      _                              -> panic "Mismatched terms in eqv (Slice)" ["Left", showPP l, "Right", showPP r]

instance Eqv p => Eqv (CallNode p) where
  eqv CallNode { callClass = cl1, callSlices = paths1 }
      CallNode { callClass = cl2, callSlices = paths2 } =
    -- trace ("Eqv " ++ showPP cn ++ " and " ++ showPP cn') $
    cl1 `eqv` cl2 && paths1 == paths2

instance Eqv SLExpr where
  eqv l r =
    case (l,r) of
      (EHole {}, EHole {})    -> True
      (EHole {}, _)           -> False
      (_, EHole {})           -> False
      (SVar {}, SVar {})      -> True
      (SPureLet _x e1 e2 , SPureLet _x' e1' e2') ->
        (e1, e2) `eqv` (e1', e2')
      (SStruct _ty fs, SStruct _ty' fs') -> map snd fs `eqv` map snd fs'
      (SECase e, SECase e') -> e `eqv` e'
      (SAp0 {}, SAp0 {})   -> True
      (SAp1 _op e, SAp1 _op' e') -> e `eqv` e'
      (SAp2 _op e1 e2, SAp2 _op' e1' e2') -> (e1, e2) `eqv` (e1', e2')
      (SAp3 _op e1 e2 e3, SAp3 _op' e1' e2' e3') ->
        (e1, e2, e3) `eqv` (e1', e2', e3')
      (SApN _op es, SApN _op' es') -> es `eqv` es'
      _ -> panic "Mismatched terms in eqv (SLExpr)" ["Left", showPP l, "Right", showPP r]      

instance Eqv a => Eqv (Case a) where
  eqv (Case _e alts1) (Case _e' alts2) =
    and (zipWith (eqv `on` snd) alts1 alts2)

-- Merging
--
-- Similar to a semigroup, but with more restrictions about how it can
-- be used (i.e., the merged objects come from the same program)

class Merge a where
  merge :: a -> a -> a

instance Eq p => Merge (CallNode p) where
  merge cn@CallNode { callClass = cl1, callSlices = sls1}
           CallNode { callClass = cl2, callSlices = sls2 }
    | cl1 /= cl2 = panic "Saw different function classes" []
    -- FIXME: check that the sets don't overlap
    | otherwise =
      -- trace ("Merging " ++ showPP cn ++ " and " ++ showPP cn') $
      -- Note: it is OK to use as the maps are disjoint
      cn { callSlices = Map.union sls1 sls2 }

instance Merge a => Merge (Case a) where
  merge (Case e alts1) (Case _e alts2) = Case e (zipWith goAlt alts1 alts2)
    where
      goAlt (p, a1) (_p, a2) = (p, merge a1 a2)

instance Merge Slice where
  merge l r =
    case (l, r) of
      (SHole {}, _)                  -> r
      (_       , SHole {})           -> l
      (SPure e, SPure e')            -> SPure (merge e e')
      (SDo x1 slL1 slR1, SDo _x2 slL2 slR2) ->
        SDo x1 (merge slL1 slL2) (merge slR1 slR2)
      (SMatch {}, SMatch {})         -> l
      (SAssertion {}, SAssertion {}) -> l
      (SChoice cs1, SChoice cs2)     -> SChoice (zipWith merge cs1 cs2)
      (SCall lc, SCall rc)           -> SCall (merge lc rc)
      (SCase t lc, SCase _ rc)       -> SCase t (merge lc rc)
      (SInverse {}, SInverse{})      -> l
      _                              -> panic "Mismatched terms in merge"
                                              ["Left", showPP l, "Right", showPP r]

instance Merge SLExpr where
  merge l r =
    case (l,r) of
      (EHole {}, _)    -> r
      (_, EHole {})    -> l
      (SVar {}, SVar {}) -> l
      (SPureLet x e1 e2 , SPureLet _x e1' e2') ->
        SPureLet x (merge e1 e1') (merge e2 e2')
      (SStruct ty fs, SStruct _ty fs') ->
        -- FIXME: we assume the orders match up here.
        SStruct ty [ (l', merge e e') | ((l', e), (_, e')) <- zip fs fs' ] 
      (SECase e, SECase e') -> SECase (merge e e')
      (SAp0 {}, SAp0 {})   -> l
      (SAp1 op e, SAp1 _op e') -> SAp1 op (merge e e')
      (SAp2 op e1 e2, SAp2 _op e1' e2') -> SAp2 op (merge e1 e1') (merge e2 e2')
      (SAp3 op e1 e2 e3, SAp3 _op e1' e2' e3') ->
        SAp3 op (merge e1 e1') (merge e2 e2') (merge e3 e3')
      (SApN op es, SApN _op es') -> SApN op (zipWith merge es es')
      _ -> panic "Mismatched terms in merge (SLExpr)" ["Left", showPP l, "Right", showPP r]

--------------------------------------------------------------------------------
-- Free instances
--
--  Used for getting deps for the SMT solver defs.

instance FreeVars Slice where
  freeVars sl =
    case sl of
      SHole {}       -> mempty
      SPure   v      -> freeVars v -- FIXME: ignores fset, which night not be what we want
      SDo x l r      -> freeVars l `Set.union` Set.delete x (freeVars r)
      SMatch m       -> freeVars m
      SChoice cs     -> foldMap freeVars cs
      SCall cn       -> freeVars cn
      SCase _ c      -> freeVars c
      SAssertion e   -> freeVars e      
      SInverse n f p -> Set.delete n (freeVars f <> freeVars p)

  freeFVars sl =
    case sl of
      SHole {}       -> mempty
      SDo _x l r     -> freeFVars l `Set.union` freeFVars r
      SPure v        -> freeFVars v
      SMatch m       -> freeFVars m
      SAssertion e   -> freeFVars e
      SChoice cs     -> foldMap freeFVars cs
      SCall cn       -> freeFVars cn
      SCase _ c      -> freeFVars c
      -- the functions in f should not be e.g. sent to the solver
      -- FIXME: what about other usages of this function?
      SInverse _ _f p -> {- freeFVars f <> -} freeFVars p 

instance FreeVars (CallNode p) where
  freeVars cn  = foldMap freeVars (Map.elems (callSlices cn))
  freeFVars cn = Set.singleton (callName cn) 

-- -----------------------------------------------------------------------------
-- FreeTCons
traverseUserTypesMap :: (Ord a, TraverseUserTypes a, TraverseUserTypes b, Applicative f) =>
                        (UserType -> f UserType) -> Map a b -> f (Map a b)
traverseUserTypesMap f = fmap Map.fromList . traverseUserTypes f . Map.toList

instance TraverseUserTypes Slice where
  traverseUserTypes f sl =
    case sl of
      SHole            -> pure SHole
      SPure v          -> SPure <$> traverseUserTypes f v
      SDo x l r        -> SDo  <$> traverseUserTypes f x
                               <*> traverseUserTypes f l
                               <*> traverseUserTypes f r      
      SMatch m         -> SMatch <$> traverseUserTypes f m
      SAssertion e     -> SAssertion <$> traverseUserTypes f e
      SChoice cs       -> SChoice <$> traverseUserTypes f cs
      SCall cn         -> SCall   <$> traverseUserTypes f cn
      SCase b c        -> SCase b <$> traverseUserTypes f c
      SInverse n ifn p -> SInverse n <$> traverseUserTypes f ifn <*> traverseUserTypes f p

instance TraverseUserTypes (CallNode p) where
  traverseUserTypes f cn  =
    (\n' -> cn { callName = n' }) <$> traverseUserTypes f (callName cn)

instance (Ord p, TraverseUserTypes p) => TraverseUserTypes (SummaryClass p) where
  traverseUserTypes _f Assertions = pure Assertions
  traverseUserTypes f (Result r) = Result <$> traverseUserTypes f r

--------------------------------------------------------------------------------
-- PP Instances
-- instance PP CallInstance where
--   ppPrec n (CallInstance { callParams = ps, callSlice = sl }) =
--     wrapIf (n > 0) $ pp ps <+> "-->" <+> pp sl

instance PP (CallNode p) where
  ppPrec n CallNode { callName = fname, callSlices = sls } =
    wrapIf (n > 0) $ pp fname
    <+> vcat (map (\(n', vs) -> brackets (pp n') <> parens (commaSep (map ppA vs))) (Map.toList sls))
    where
      ppA Nothing = "_"
      ppA (Just v) = pp v
    
-- c.f. PP Grammar
instance PP Slice where
  pp sl =
    case sl of
      SHole          -> "[]"
      SPure e        -> "pure" <+> ppPrec 1 e
      SMatch e       -> "match" <+> pp e
      SDo  {}        -> "do" <+> ppStmts' sl
      SChoice cs     -> "choice" <> block "{" "," "}" (map pp cs)
      SCall cn       -> pp cn
      SCase _ c      -> pp c
      SAssertion e   -> "assert" <+> ppPrec 1 e
      SInverse n' ifn p -> -- wrapIf (n > 0) $
        "inverse for" <+> ppPrec 1 n' <+> "is" <+> ppPrec 1 ifn <+> "/" <+> ppPrec 1 p
      
ppStmts' :: Slice -> Doc
ppStmts' sl =
  case sl of
    SDo x g1 g2 -> pp x <+> "<-" <+> pp g1 $$ ppStmts' g2
    _           -> pp sl

instance PP FInstId where
  pp (FInstId i) = pp i

instance PP p => PP (SummaryClass p) where
  pp Assertions = "Assertions"
  pp (Result p) = "Result" <+> brackets (commaSep (map pp (Set.toList p)))
