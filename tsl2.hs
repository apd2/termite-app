{-# LANGUAGE FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, ScopedTypeVariables, RecordWildCards, UndecidableInstances, TupleSections, ImplicitParams #-}

module Main where

import qualified Data.Map as M
import Data.Tuple.Select
import Data.Maybe
import Control.Monad
import Control.Monad.ST
import Control.Monad.Trans
import Control.Monad.Trans.Identity
import Control.Error
import System.Environment
import qualified Text.PrettyPrint as P
import System.Console.GetOpt

import Util
import SpecInline
import PP
import Parse
import Spec
import SpecOps
import DbgGUI
import DbgTypes
import Cudd
import CuddExplicitDeref
import SMTLib2
import SourceView
import SourceViewTypes
import StrategyView
import AbstractorIFace
import RefineCommon
import TermiteGame
import RefineUtil
import TSLAbsGame
import BVSMT
import Store
import SMTSolver
import Predicate
import Resource
import qualified ISpec    as I
import qualified TranSpec as I
--  import Spec2ASL

data TOption = InputTSL String
             | ImportDir String
             | BoundRefines String
             | DoSynthesis
             | QBFSynthesis
             | NoBuiltins
             | ASLConvert
        
options :: [OptDescr TOption]
options = [ Option ['i'] []             (ReqArg InputTSL "FILE")       "input TSL file"
          , Option ['I'] []             (ReqArg ImportDir "DIRECTORY") "additional import lookup directory"
          , Option ['s'] []             (NoArg DoSynthesis)            "perform synthesis"
          , Option ['q'] []             (NoArg QBFSynthesis)           "run QBF-based synthesis after normal synthesis"
          , Option ['r'] []             (ReqArg BoundRefines "n")      "bound the number of refinements"
          , Option []    ["nobuiltins"] (NoArg NoBuiltins)             "do not include TSL2 builtins"
          , Option []    ["asl"]        (NoArg ASLConvert)             "try to convert spec to ASL format"]

data Config = Config { confTSLFile      :: FilePath
                     , confImportDirs   :: [FilePath]
                     , confBoundRefines :: Maybe Int
                     , confDoSynthesis  :: Bool
                     , confQBFSynthesis :: Bool
                     , confNoBuiltins   :: Bool
                     , confDoASL        :: Bool }

defaultConfig = Config { confTSLFile      = ""
                       , confImportDirs   = []
                       , confBoundRefines = Nothing
                       , confDoSynthesis  = False
                       , confQBFSynthesis = False
                       , confNoBuiltins   = False
                       , confDoASL        = False}

addOption :: TOption -> Config -> Config
addOption (InputTSL f)     config = config{ confTSLFile      = f}
addOption (ImportDir dir)  config = config{ confImportDirs   = (confImportDirs config) ++ [dir]}
addOption (BoundRefines b) config = config{ confBoundRefines = case reads b of
                                                                    []        -> trace "invalid bound specified" Nothing
                                                                    ((i,_):_) -> Just i}
addOption DoSynthesis      config = config{ confDoSynthesis  = True}
addOption QBFSynthesis     config = config{ confDoSynthesis  = True
                                          , confQBFSynthesis = True}
addOption NoBuiltins       config = config{ confNoBuiltins   = True}
addOption ASLConvert       config = config{ confDoASL        = True}

main = do
    args <- getArgs
    prog <- getProgName
    config <- case getOpt Permute options args of
                   (flags, [], []) -> return $ foldr addOption defaultConfig flags
                   _ -> fail $ usageInfo ("Usage: " ++ prog ++ " [OPTION...]") options 
    spec <- parseTSL (confTSLFile config) (confImportDirs config) (not $ confNoBuiltins config)
    writeFile "output.tsl" $ P.render $ pp spec
    case validateSpec spec of
         Left e  -> fail $ "validation error: " ++ e
         Right _ -> putStrLn "validation successful"
    spec' <- case flatten spec of
                  Left e  -> fail $ "flattening error: " ++ e
                  Right s -> return s
    writeFile "output2.tsl" $ P.render $ pp spec'
    case validateSpec spec' of
         Left e  -> fail $ "flattened spec validation error: " ++ e
         Right _ -> putStrLn "flattened spec validation successful"
    let ispecFull = spec2Internal spec'
        ispecDummy = ispecFull {I.specTran = (I.specTran ispecFull) { I.tsCTran = []
                                                                    , I.tsUTran = []}}
        ispec = if' (confDoSynthesis config) ispecFull ispecDummy
        solver = newSMTLib2Solver ispecFull z3Config
    writeFile "output3.tsl" $ P.render $ pp ispec
    -- when (confDoASL config) $ writeFile "output.asl"  $ P.render $ spec2ASL ispec

    withManagerIODefaults $ \m -> do

        stToIO $ setupManager m

        (ri, model, absvars, sfact, inuse) <- do ((ri, res, avars, model, mstrategy), inuse) <- synthesise m config spec spec' ispec solver (confDoSynthesis config)
                                                 putStrLn $ "Synthesis returned " ++ show res
                                                 putStrLn $ "inuse: " ++ show inuse
                                                 return (ri, model, avars, if' (isJust mstrategy) [(strategyViewNew $ fromJust mstrategy, True)] [], inuse)
        when (confQBFSynthesis config) $ qbfSynth $ map ((absvars M.!) . sel1) $ mStateVars model
        putStrLn "starting debugger"
        let sourceViewFactory = sourceViewNew spec spec' ispec absvars solver m ri inuse
        debugGUI ((sourceViewFactory, True):(if' (confDoSynthesis config) sfact [])) model

synthesise :: STDdManager RealWorld u 
           -> Config 
           -> Spec 
           -> Spec 
           -> I.Spec 
           -> SMTSolver 
           -> Bool 
           -> IO ((RefineInfo RealWorld u AbsVar AbsVar [[AbsVar]], Maybe Bool, M.Map String AbsVar, Model DdManager DdNode Store SVStore, Maybe (Strategy DdNode)), InUse (DDNode RealWorld u))
synthesise m conf inspec flatspec spec solver dostrat = stToIO $ runResourceT M.empty $ do
    let ts    = bvSolver spec solver m 
        agame = tslAbsGame spec m ts

    (win, ri) <- absRefineLoop m agame ts (confBoundRefines conf)
    sr <- mkSynthesisRes spec m (if' dostrat win Nothing, ri)

    let model    = mkModel inspec flatspec spec solver sr
        strategy = mkStrategy spec sr
        (svars, sbits, lvars, lbits) = srStats sr

    lift $ traceST $ "Concrete variables used in the final abstraction: " ++
                            "state variables: " ++ show svars ++ "(" ++ show sbits ++ "bits), " ++ 
                            "label variables: "++ show lvars ++ "(" ++ show lbits ++ "bits)"

    return (ri, srWin sr, srAbsVars sr, model, strategy)

qbfSynth :: [AbsVar] -> IO ()
qbfSynth avs = do
    putStrLn "Running QBF synthesis"
    
--tslUpdateAbsVarAST :: (?spec::Spec, ?pred::[Predicate]) => (AbsVar, f) -> TAST f e c
