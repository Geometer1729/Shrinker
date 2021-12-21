module Shrink.Tactics.Util where

import Shrink.Types
import Shrink.ScopeM

import Control.Arrow                (first,second)
import Control.Monad                (join, liftM2, guard)
import Control.Monad.Reader         (MonadReader,ask, local, runReaderT)
import Control.Monad.State          (get, modify, put, runStateT)
import Data.Functor                 ((<&>))
import Data.Functor.Identity        (Identity(Identity),runIdentity)
import Data.Map                     (Map)
import Data.Maybe                   (fromMaybe)
import Data.Text                    (pack)

import UntypedPlutusCore.Core.Type  (Term (Apply, Builtin, Constant , Delay, Error, Force, LamAbs, Var))
import PlutusCore.Default           (DefaultFun (..))
import UntypedPlutusCore            (Name (Name), Unique (Unique))

import qualified Data.Map as M
import qualified Data.Set as S

completeTactic :: PartialTactic -> Tactic
completeTactic = runScopedTact . completeTactic'

completeTactic' :: PartialTactic -> ScopedTactic
completeTactic' pt term = do
  let st = completeTactic' pt
  extras <- fromMaybe [] <$> pt term
  descend st term <&> (++ extras)

descend :: ScopedTactic -> ScopedTactic
descend tact = \case
       Var _ name -> return [Var () name]
       LamAbs _ name term -> fmap (LamAbs () name) <$> addNameToScope name (tact term)
       Apply _ funTerm varTerm -> do
         funTerms <- tact funTerm
         varTerms <- tact varTerm
         return $ Apply () funTerm varTerm :
               [Apply () funTerm' varTerm  | funTerm' <- drop 1 funTerms ]
            ++ [Apply () funTerm  varTerm' | varTerm' <- drop 1 varTerms ]
       Force _ term -> fmap (Force ()) <$> tact term
       Delay _ term -> fmap (Delay ()) <$> tact term
       Constant _ val -> return [Constant () val]
       Builtin _ fun  -> return [Builtin () fun]
       Error _ -> return [Error ()]

addNameToScope :: MonadReader (Scope,Scope) m => Name -> m a -> m a
addNameToScope name = local $ second (S.insert name)

completeRec :: (NTerm -> Maybe NTerm) -> NTerm -> NTerm
completeRec partial = runIdentity . completeRecM (Identity . partial)

completeRecM :: Monad m => (NTerm -> m (Maybe NTerm)) -> NTerm -> m NTerm
completeRecM partial originalTerm = let
  rec = completeRecM partial
    in partial originalTerm >>= \case
      Just term -> return term
      Nothing ->
        case originalTerm of
          LamAbs _ name term -> LamAbs () name <$> rec term
          Apply  _ f x       -> Apply  () <$> rec f <*> rec x
          Force  _ term      -> Force  () <$> rec term
          Delay  _ term      -> Delay  () <$> rec term
          term               -> return term

appBind :: Name -> NTerm -> NTerm -> NTerm
appBind name val = completeRec $ \case
      Var _ varName -> if name == varName
                               then Just val
                               else Nothing
      _ -> Nothing

mentions :: Name -> NTerm -> Bool
mentions name = \case
  Var _ vname         -> vname == name
  LamAbs _ lname term -> lname /= name && mentions name term
  Apply _ f x         -> mentions name f || mentions name x
  Force _ term        -> mentions name term
  Delay _ term        -> mentions name term
  _                   -> False

whnf :: NTerm -> WhnfRes
whnf = whnf' 100

whnf' :: Integer -> NTerm -> WhnfRes
whnf' 0 = const Unclear
whnf' n = let
  rec = whnf' (n-1)
    in \case
  Var{} -> Safe
  -- While Vars can be bound to error
  -- that lambda will throw an error first so this is safe
  LamAbs{} -> Safe
  Apply _ (LamAbs _ name lTerm) valTerm ->
    case rec valTerm of
      Err -> Err
      res -> min res $ rec (appBind name valTerm lTerm)
  Apply _ (Apply _ (Builtin _ builtin) arg1) arg2 ->
    if safe2Arg builtin
       then min (rec arg1) (rec arg2)
       else min Unclear $ min (rec arg1) (rec arg2)
  Apply _ fTerm xTerm -> min Unclear $ min (rec fTerm) (rec xTerm)
    -- it should be possible to make this clear more often
    -- ie. a case over builtins
  Force _ (Delay _ term) -> rec term
  Force{} -> Unclear
  Delay{} -> Safe
  Constant{} -> Safe
  Builtin{} -> Safe
  Error{} -> Err

safe2Arg :: DefaultFun -> Bool
safe2Arg = \case
  AddInteger               -> True
  SubtractInteger          -> True
  MultiplyInteger          -> True
  EqualsInteger            -> True
  LessThanInteger          -> True
  LessThanEqualsInteger    -> True
  AppendByteString         -> True
  ConsByteString           -> True
  IndexByteString          -> True
  EqualsByteString         -> True
  LessThanByteString       -> True
  LessThanEqualsByteString -> True
  VerifySignature          -> True
  AppendString             -> True
  EqualsString             -> True
  ChooseUnit               -> True
  Trace                    -> True
  MkCons                   -> True
  ConstrData               -> True
  EqualsData               -> True
  MkPairData               -> True
  _                        -> False

subTerms :: NTerm -> [(Scope,NTerm)]
subTerms t = (S.empty,t):case t of
                 LamAbs _ n term         -> first (S.insert n) <$> subTerms term
                 Apply _ funTerm varTerm -> subTerms funTerm ++ subTerms varTerm
                 Force _ term            -> subTerms term
                 Delay _ term            -> subTerms term
                 Var{}                   -> []
                 Constant{}              -> []
                 Builtin{}               -> []
                 Error{}                 -> []

unsub :: NTerm -> Name -> NTerm -> NTerm
unsub replacing replaceWith = completeRec $ \case
  term
    | term == replacing -> Just $ Var () replaceWith
  _ -> Nothing

equiv :: (Scope,NTerm) -> (Scope,NTerm) -> Bool
equiv (lscope,lterm) (rscope,rterm)
     = not (uses lscope lterm)
    && not (uses rscope rterm)
    && lterm == rterm

-- compares two (scoped) terms and maybe returns a template
-- the number of nodes of the template and the holes in the template
weakEquiv :: (Scope,NTerm) -> (Scope,NTerm) -> ScopeMT Maybe (NTerm,Integer,[Name])
weakEquiv (lscope,lterm) (rscope,rterm) = do
    -- ensure that unshared scope is not used
    guard $ not (uses lscope lterm)
    guard $ not (uses rscope rterm)
    weakEquiv' lterm rterm

weakEquiv' :: NTerm -> NTerm -> ScopeMT Maybe (NTerm,Integer,[Name])
weakEquiv' = curry $ \case
  (LamAbs _ ln lt,LamAbs _ rn rt)
    | ln == rn -> do
      (t,n,hs) <- weakEquiv' lt rt
      return (LamAbs () ln t,n,hs)
    | otherwise -> do
      rt' <- subName ln rn rt
      (t,n,hs) <- weakEquiv' lt rt'
      return (LamAbs () ln t,n,hs)
  (Apply _ lf lx,Apply _ rf rx) -> do
    (ft,fnodes,fholes) <- weakEquiv' lf rf
    (xt,xnodes,xholes) <- weakEquiv' lx rx
    return (Apply () ft xt,fnodes+xnodes,fholes++xholes)
  (Delay _ l,Delay _ r) -> do
    (t,n,h) <- weakEquiv' l r
    return (Delay () t,n+1,h)
  (Force _ l,Force _ r) -> do
    (t,n,h) <- weakEquiv' l r
    return (Force () t,n+1,h)
  (l,r)
    | l == r    -> return (l,1,[])
    | otherwise -> do
        guard $ whnf l == Safe
        guard $ whnf r == Safe
        holeName <- newName
        return (Var () holeName,1,[holeName])

subName :: MonadScope m => Name -> Name -> NTerm -> m NTerm
subName replace replaceWith term = do
  new <- newName
  return $ subName' replace replaceWith $ subName' replaceWith new term

subName' :: Name -> Name -> NTerm -> NTerm
subName' replace replaceWith = completeRec $ \case
  LamAbs _ n t -> Just $ LamAbs () (if n == replace then replaceWith else n) (subName' replace replaceWith t)
  Var _ n      -> Just $ Var () (if n == replace then replaceWith else n)
  _ -> Nothing

uses :: Scope -> NTerm -> Bool
uses s = \case
  Apply _ f x  -> uses s f || uses s x
  Delay _ t    -> uses s t
  Force _ t    -> uses s t
  LamAbs _ n t -> n `S.notMember` s && uses s t
  Var _ n      -> n `S.member` s
  _            -> False

newName :: MonadScope m => m Name
newName = do
  n <- get
  modify (+1)
  return $ Name (pack $ show n) (Unique $ fromIntegral n)

sepMaybe :: ScopeMT Maybe a -> ScopeM (Maybe a)
sepMaybe smtma = do
  s <- ask
  f <- get
  case runStateT (runReaderT smtma s) f of
    Just (a,f') -> put f' >> return (Just a)
    Nothing     -> return Nothing

makeLambs :: [Name] -> NTerm -> NTerm
makeLambs = flip $ foldr (LamAbs ())


withTemplate :: Name -> (NTerm,[Name]) -> NTerm -> ScopeM NTerm
withTemplate templateName (template,holes) = completeRecM $ \target -> do
  margs <- findHoles holes template target
  return $ do
    mapArgs <- margs
    let args = M.elems mapArgs
    guard $ all (== Safe) (whnf <$> args)
    return $ applyArgs (Var () templateName) args

findHoles :: [Name] -> NTerm -> NTerm -> ScopeM (Maybe (Map Name NTerm))
findHoles holes template subTerm
  | template == subTerm = return $ Just M.empty
  | otherwise = case (template,subTerm) of
    (Var () nt,st)
      | nt `elem` holes -> return $ Just $ M.singleton nt st
    (Force _ t,Force _ s)  -> findHoles holes t s
    (Delay _ t,Delay _ s)  -> findHoles holes t s
    (LamAbs _ tn tt,LamAbs _ sn st)
      | tn == sn -> findHoles holes tt st
      | otherwise -> do
        st' <- subName tn sn st
        findHoles holes tt st'
    (Apply _ tf tx,Apply _ sf sx) -> join <$> liftM2 (liftM2 reconsile)
      (findHoles holes tf sf)
      (findHoles holes tx sx)
    _ -> return Nothing

reconsile :: (Ord k,Eq a) => Map k a -> Map k a -> Maybe (Map k a)
reconsile m1 m2 = do
  guard $ and $ M.intersectionWith (==) m1 m2
  return $ M.union m1 m2

applyArgs :: NTerm -> [NTerm] -> NTerm
applyArgs = foldl (Apply ())