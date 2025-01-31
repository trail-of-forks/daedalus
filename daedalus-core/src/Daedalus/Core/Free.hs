module Daedalus.Core.Free where

import Data.Set(Set)
import qualified Data.Set as Set

import Daedalus.Core.Basics
import Daedalus.Core.Expr
import Daedalus.Core.ByteSet
import Daedalus.Core.Grammar
import Daedalus.Core.Decl

import Daedalus.Core.TraverseUserTypes

-- | Compute value-level dependencies
class FreeVars t where
  freeVars :: t -> Set Name
  freeFVars :: t -> Set FName

-- | Compute user-defined type dependencies
freeTCons :: TraverseUserTypes t => t -> Set TName
freeTCons = foldMapUserTypes (\ut -> Set.insert (utName ut) (freeTCons (utTyArgs ut)))

instance FreeVars a => FreeVars [a] where
  freeVars = Set.unions . map freeVars
  freeFVars = Set.unions . map freeFVars

instance FreeVars Name where
  freeVars = Set.singleton
  freeFVars _ = mempty
  
instance FreeVars Expr where
  freeVars expr =
    case expr of
      Var x           -> freeVars x
      PureLet x e1 e2 -> freeVars e1 `Set.union` Set.delete x (freeVars e2)
      Struct _ fs     -> Set.unions [ freeVars e | (_,e) <- fs ]
      ECase e         -> freeVars e
      Ap0 _           -> Set.empty
      Ap1 _ e         -> freeVars e
      Ap2 _ e1 e2     -> freeVars [e1,e2]
      Ap3 _ e1 e2 e3  -> freeVars [e1,e2,e3]
      ApN _ es        -> freeVars es

  freeFVars expr =
    case expr of
      Var x           -> freeFVars x
      PureLet _ e1 e2 -> freeFVars [e1,e2]
      Struct _ fs     -> Set.unions [ freeFVars e | (_,e) <- fs ]
      ECase e         -> freeFVars e
      Ap0 _           -> Set.empty
      Ap1 _ e         -> freeFVars e
      Ap2 _ e1 e2     -> freeFVars [e1,e2]
      Ap3 _ e1 e2 e3  -> freeFVars [e1,e2,e3]
      ApN op es ->
        let fs = freeFVars es
        in case op of
            CallF f  -> Set.insert f fs
            ArrayL _ -> fs



instance FreeVars Grammar where
  freeVars gram =
    case gram of
      Pure e            -> freeVars e
      GetStream         -> Set.empty
      SetStream e       -> freeVars e
      Match _ e         -> freeVars e
      Fail _ _ e        -> freeVars e
      Do_ g1 g2         -> freeVars [g1,g2]
      Do  x g1 g2       -> freeVars g1 `Set.union` Set.delete x (freeVars g2)
      Let x e g         -> freeVars e  `Set.union` Set.delete x (freeVars g)
      OrBiased g1 g2    -> freeVars [g1,g2]
      OrUnbiased g1 g2  -> freeVars [g1,g2]
      Call _ es         -> freeVars es
      Annot _ g         -> freeVars g
      GCase c           -> freeVars c

  freeFVars gram =
    case gram of
      Pure e            -> freeFVars e
      GetStream         -> Set.empty
      SetStream e       -> freeFVars e
      Match _ e         -> freeFVars e
      Fail _ _ e        -> freeFVars e
      Do_ g1 g2         -> freeFVars [g1,g2]
      Do  _ g1 g2       -> freeFVars [g1,g2]
      Let _ e g         -> freeFVars e `Set.union` freeFVars g
      OrBiased g1 g2    -> freeFVars [g1,g2]
      OrUnbiased g1 g2  -> freeFVars [g1,g2]
      Call f es         -> Set.insert f (freeFVars es)
      Annot _ g         -> freeFVars g
      GCase c           -> freeFVars c

instance FreeVars Match where
  freeVars mat =
    case mat of
      MatchBytes e  -> freeVars e
      MatchByte e   -> freeVars e
      MatchEnd      -> Set.empty

  freeFVars mat =
    case mat of
      MatchBytes e  -> freeFVars e
      MatchByte e   -> freeFVars e
      MatchEnd      -> Set.empty

instance FreeVars ByteSet where
  freeVars bs =
    case bs of
      SetAny -> Set.empty
      SetSingle e -> freeVars e
      SetRange e1 e2 -> freeVars [e1,e2]
      SetComplement x -> freeVars x
      SetUnion x y    -> freeVars [x,y]
      SetIntersection x y -> freeVars [x,y]
      SetCall _ es -> freeVars es
      SetCase e -> freeVars e
      SetLet x e k -> freeVars e `Set.union` Set.delete x (freeVars k)

  freeFVars bs =
    case bs of
      SetAny -> Set.empty
      SetSingle e -> freeFVars e
      SetRange e1 e2 -> freeFVars [e1,e2]
      SetComplement x -> freeFVars x
      SetUnion x y    -> freeFVars [x,y]
      SetIntersection x y -> freeFVars [x,y]
      SetCall f es -> Set.insert f (freeFVars es)
      SetCase e -> freeFVars e
      SetLet _ e1 e2 -> freeFVars e1 `Set.union` freeFVars e2


instance FreeVars e => FreeVars (Case e) where
  freeVars  (Case v opts) = Set.insert v (freeVars (map snd opts))
  freeFVars (Case _ opts) = freeFVars (map snd opts)

instance FreeVars e => FreeVars (FunDef e) where
  freeVars def =
    case def of
      Def e -> freeVars e
      External -> Set.empty

  freeFVars def =
    case def of
      Def e -> freeFVars e
      External -> Set.empty


instance FreeVars e => FreeVars (Fun e) where
  freeVars f = freeVars (fDef f) `Set.difference` Set.fromList (fParams f)
  freeFVars f = freeFVars (fDef f)

instance FreeVars e => FreeVars (Maybe e) where
  freeVars  = maybe mempty freeVars
  freeFVars = maybe mempty freeFVars
