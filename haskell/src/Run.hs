module Run ( runEnv
           , Opts (..)
           , Result
           , SatDict
           , Log
           , test2
           ) where

import qualified Data.Map.Strict as M
import Control.Monad.RWS.Strict
import qualified Data.SBV.Internals  as I
import qualified Data.SBV            as S
import qualified Data.SBV.Control    as SC
import Debug.Trace (trace)

import qualified Data.Set            as Set

import GHC.Generics
import Control.DeepSeq               (NFData)

import Data.Maybe                    (fromMaybe, catMaybes)

import VProp
import V

-- | The satisfiable dictionary, this is actually the "state" keys are configs
-- and values are whether that config is satisfiable or not (a bool)
type SatDict a = (M.Map Config Bool, M.Map a Bool) -- keys may incur perf penalty

-- | The optimizations that could be set
data Opts a = Opts { runBaselines :: Bool              -- ^ Run baselines?
                 , runAD :: Bool                     -- ^ run anddecomp baseline? else Brute Force
                 , runOpts :: Bool                   -- ^ Run optimizations or not?
                 , optimizations :: [(VProp a) -> (VProp a)] -- ^ a list of optimizations
                 }

-- | Type convenience for Log
type Log = String

-- | Takes a dimension d, a value a, and a result r
type Env a r = RWST (Opts a) Log (SatDict a) IO r -- ^ the monad stack

-- | An empty reader monad environment, in the future read these from config file
_emptyOpts :: (Opts a)
_emptyOpts = Opts { runBaselines = False
                  , runAD = False
                  , runOpts = False
                  , optimizations = []
                  }


_setOpts :: Bool -> Bool -> Bool -> [VProp a -> VProp a] -> Opts a
_setOpts base bAD bOpt opts = Opts { runBaselines = base
                                  , runAD = bAD
                                  , runOpts = bOpt
                                  , optimizations = opts
                                  }



-- | Run the RWS monad with defaults of empty state, reader
_runEnv :: Env a r -> Opts a -> (SatDict a) -> IO (r, (SatDict a),  Log)
_runEnv m opts st = runRWST m opts st

-- TODO use configurate and load the config from a file
runEnv :: Bool -> Bool -> Bool -> [VProp String -> VProp String] -> VProp String -> IO (Result, (SatDict String), Log)
runEnv base bAD bOpt opts x = _runEnv
                             (work x)
                             (_setOpts base bAD bOpt opts)
                             (initSt x)


-- | Given a VProp a term generate the satisfiability map
initSt :: (Show a, Ord a) => VProp a -> (SatDict a)
initSt prop = (sats, vs)
  where sats = M.fromList . fmap (\x -> (x, False)) $ M.fromList <$> configs prop
        vs = M.fromSet (const False) (vars prop)


-- | Some logging functions
_logBaseline :: (Show a, MonadWriter [Char] m) => a -> m ()
_logBaseline x = tell $ "Running baseline: " ++ show x

_logCNF :: (Show a, MonadWriter [Char] m) => a -> m ()
_logCNF x = tell $ "Generated CNF: " ++ show x

_logResult :: (Show a, MonadWriter [Char] m) => a -> m ()
_logResult x = tell $ "Got result: " ++ show x


-- | Run the brute force baseline case, that is select every plain variant and
-- run them to the sat solver
runBruteForce :: (Show a, Ord a) =>
  (MonadTrans t, MonadState (SatDict a) (t IO)) => VProp a -> t IO [S.SatResult]
runBruteForce prop = {-# SCC "brute_force"#-} do
  (_confs, _) <- get
  let confs = M.keys _confs
      plainProps = (\y -> sequence $ (y, selectVariant y prop)) <$> confs
  -- this line is always throwing a Nothing
  plainModels <- lift $ mapM (S.sat . symbolicPropExpr . snd) $ catMaybes plainProps
  return plainModels

-- | Run the and decomposition baseline case, that is deconstruct every choice
-- and then run the sat solver
runAndDecomp :: VProp String -> IO (Maybe I.SMTModel)
runAndDecomp prop = {-# SCC "andDecomp" #-} S.runSMT $ do
  p <- symbolicPropExpr $ (andDecomp prop dimName)
  S.constrain p
  SC.query $ do
    c <- SC.checkSat
    case c of
      SC.Unk -> error "asdf"
      SC.Unsat -> return Nothing
      SC.Sat -> do model' <- SC.getModel
                   return $ Just model'

-- | main workhorse for running the SAT solver
data Result = R (Maybe I.SMTModel)
            | L [S.SatResult]
            | Vr [V Dim (Maybe I.SMTModel)]
            deriving Generic

instance NFData Result

work :: ( MonadTrans t
        , MonadState (SatDict String) (t IO)
        , MonadReader (Opts String) (t IO)) => VProp String -> t IO Result
work prop = do
  baselines <- asks runBaselines
  bAD <- asks runAD
  -- fix this antipattern later
  if baselines
    then if bAD
         then lift $ runAndDecomp prop  >>= return . R
         else do
    runBruteForce prop >>= return . L
    else do
    opts <- asks optimizations
    result <- lift $ incrementalSolve prop opts
    return $ Vr result

-- | given VProp a, incrementally solve it using variational tricks and SBV
incrementalSolve :: (Show a, Ord a) => VProp a -> [VProp a -> VProp a] -> IO [V Dim (Maybe I.SMTModel)]
incrementalSolve prop opts = {-# SCC "choice_solver"#-} solveChoice prop

-- -- | convert a list of dims to symbolic dims, and keep the association
-- dimBoolMap :: [Dim] -> S.Symbolic [(Dim, S.SBool)]
-- dimBoolMap =  traverse (\x -> sequence (x, S.sBool $ dimName x))

-- -- | combine a list of dims and symbolic dims with a list of configs, this returns
-- -- a config with the symbolic dim in the snd position
-- mkPaths :: [(Dim, S.SBool)] -> [[(Dim, Bool)]] -> [[(Dim, S.SBool, Bool)]]
-- mkPaths dimBools pths = fmap (\(dim, bl) ->
--                                 (dim, fromJust $ lookup dim dimBools, bl)) <$> pths

-- | Given a 3 tuple use the symbolic dim and the boolean to set a query constraint
cConstrain :: (Dim, S.SBool) -> Bool -> SC.Query ()
cConstrain (_, sDim) bl = assocToConstraint (sDim, bl) >>= S.constrain

-- | perform a query with a choice expression. This assumes the query monad
-- knows about the dimension variables, the plain variables, and the expression
-- to solve. It then pushes teh assertion stack, constrains the dimension
-- variables according to its config, then pops the assertion stack and returns
-- the internal model
_cQuery :: (Dim, S.SBool) -> Bool -> SC.Query (Maybe I.SMTModel)
_cQuery x bl = do SC.push 1
                  cConstrain x bl
                  c <- SC.checkSat
                  case c of
                    SC.Unk   -> error "asdf"
                    SC.Unsat -> return Nothing
                    SC.Sat   -> do model' <- SC.getModel
                                   SC.pop 1
                                   return $ Just model'

cQuery :: (Dim, S.SBool) -> SC.Query (V Dim (Maybe I.SMTModel))
cQuery x@(dim, _) = do
  trueModel <- Plain <$> _cQuery x True
  falseModel <- Plain <$> _cQuery x False
  return $ VChc dim trueModel falseModel

-- | given a prop, check if it is plain, if so run SMT normally, if not run the
-- | variational solver
solveChoice :: (Show a, Ord a) => VProp a -> IO [V Dim (Maybe I.SMTModel)]
solveChoice prop
  | isPlain prop = fmap pure $ S.runSMT $ do
      p <- symbolicPropExpr prop
      S.constrain p
      SC.query $ do c <- SC.checkSat
                    case c of
                      SC.Unk   -> error "SBV failed in plain solve Choice"
                      SC.Unsat -> return $ Plain Nothing
                      SC.Sat   -> SC.getModel >>= return . Plain . Just
  | otherwise = S.runSMT $ do
      (p, ds') <- symbolicPropExpr' prop
      S.constrain p
      let ds = M.toList ds'
      res <- SC.query $ do mapM (cQuery) ds
      return res

-- | This test is simulating recursively evaluating an And in our domain the
-- list of strings are considered to be And [String] in our data type
test :: [String] -> IO (Maybe I.SMTModel)
test xs = S.runSMT $
  do
  xs' <- traverse (\a -> sequence (a, S.sBool a)) xs -- phase 1, add all vars
  loop xs' -- now the recursion
 where
   -- | perform the recursion to that semantically converts our And to SBV's &&&
   loop1 []           = S.true
   loop1 ((s, sB):ss) = sB S.&&& loop1 ss

   -- | the outer loop, run the constraint and then get a model
   loop ys = SC.query $ do S.constrain $ loop1 ys
                           cs <- SC.checkSat
                           case cs of
                             SC.Unk   -> error "Unknown!"
                             SC.Unsat -> return Nothing
                             SC.Sat   -> Just <$> SC.getModel

test2 :: VProp String -> S.Symbolic (V Dim (Maybe I.SMTModel))
test2 prop = do
  prop' <- traverse S.sBool prop -- phase 1, add all vars
  SC.query $ loop1 prop' >>= resolve
  where
    bToSb True = S.true
    bToSb False = S.false

    -- | perform the recursion so that semantically converts our And to SBV's &&&
    loop1 :: VProp S.SBool -> SC.Query (V Dim S.SBool)
    loop1 (Lit b)          = return . Plain $ if b then S.true else S.false
    loop1 (Not ps)         = loop1 $ S.bnot ps
    loop1 (Opn And [])     = return . Plain $ S.true
    loop1 (Opn Or [])      = return . Plain $ S.false
    loop1 (Opn And ss)     = foldr1 (S.&&&) $ loop1 <$> ss
    loop1 (Opn Or ss)      = loop1 $ foldr1 (S.|||) ss
    loop1 (Op2 Impl l r)   = loop1 $ l S.==> r
    loop1 (Op2 BiImpl l r) = loop1 $ l S.<=> r
    loop1 (Chc d l r)      = liftM2 (VChc d) (loop1 l) (loop1 r)
    loop1 (Ref x)          = return $ Plain x

    -- | get a model out given an S.SBool
    getModel :: SC.Query (V Dim (Maybe I.SMTModel))
    getModel = do cs <- SC.checkSat
                  case cs of
                    SC.Unk   -> error "Unknown!"
                    SC.Unsat -> return (Plain Nothing)
                    SC.Sat   -> (Plain . Just) <$> SC.getModel

    -- | recurse over the structure only getting amodel on refs and lits
    -- unbox :: VProp S.SBool -> SC.Query (V Dim (Maybe I.SMTModel))
    -- unbox (Ref x) = getModel x
    -- unbox (Lit b) = getModel $ bToSb b
    -- unbox (Chc d l r) = do l' <- unbox l; r' <- unbox r; return $ VChc d l' r'
    -- unbox x = unbox $ loop1 x

    resolve :: V Dim S.SBool -> SC.Query (V Dim (Maybe I.SMTModel))
    resolve (Plain x) = do S.constrain x
                           getModel
    resolve (VChc d l r) =
      do SC.push 1
         ml <- resolve l
         SC.pop 1
         SC.push 1
         mr <- resolve r
         SC.pop 1
         return $ VChc d ml mr

    -- loop (Opn _ (p:ps)) =  pure <$> unbox p
    -- loop (Op2 _ l r) = do l' <- unbox l
    --                       r' <- unbox r
    --                       return $ [l', r']
    -- loop x   = pure <$> unbox x



-- -- | Given two models, if both are not nothing, combine them
-- combineModels :: Maybe I.SMTModel -> Maybe I.SMTModel -> Maybe I.SMTModel
-- combineModels Nothing a = a
-- combineModels a Nothing = a
-- combineModels
--   (Just I.SMTModel{I.modelAssocs=aAs, I.modelObjectives=aOs})
--   (Just I.SMTModel{I.modelAssocs=bAs , I.modelObjectives=bOs}) =
--   (Just I.SMTModel{ I.modelAssocs= nub aAs ++ bAs
--                   , I.modelObjectives = aOs ++ bOs})

-- | Given an association between a symbolic bool variable and a normal bool,
-- add a representative constraint to the query monad
assocToConstraint :: (S.SBool, Bool) -> SC.Query S.SBool
assocToConstraint (var, val) = return $ var S..== (bToSb val)
  where bToSb True = S.true
        bToSb False = S.false

-- | Change a prop to a predicate, avoiding anything that has already been assigned
symbolicPropExpr' :: (Show a, Ord a) => VProp a -> S.Symbolic (S.SBool, M.Map Dim S.SBool)
symbolicPropExpr' prop = do
    let vs = (Set.toList (vars prop))
        ds = (Set.toList (dimensions prop))
    syms <- fmap (M.fromList . zip vs) (S.sBools (map show vs))
    dims <- fmap (M.fromList . zip ds) (S.sBools (map dimName ds))
    let look f = fromMaybe err (M.lookup f syms)
        lookd d = fromMaybe errd (M.lookup d dims)
    return ((evalPropExpr lookd look prop), dims)

  where err = error "symbolicPropExpr: Internal error, no symbol found."
        errd = error "symbolicPropExpr: Internal error, no dimension found."
