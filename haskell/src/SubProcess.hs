module SubProcess where

import qualified Turtle as T
import Turtle.Line
import Data.Text (pack)
import System.Posix.Process (getProcessID)
import Data.Maybe (catMaybes, fromJust)

import CNF
import TagTree

-- | Take anything that can be shown and pack it into a shell line
toLine :: (Show a) => a -> T.Shell Line
toLine = T.select . textToLines . pack . show

-- | Given a Variational CNF generate a config for all choices
genConfig :: CNF Variational V -> Config
genConfig = concatMap (\x -> [(x, True), (x, False)]) . catMaybes . fmap tag
            . concatMap (filter isChc) . clauses

-- | Given a config and a Variational CNF, transform to a Plain CNF
toPlain :: Config -> CNF Variational V -> CNF Plain V
toPlain cs CNF{comment,vars,clauses} =
  CNF { comment=comment
      , vars=vars
      , clauses = fmap (fmap $ one . fromJust . select cs) clauses
      }



-- | Take any Sat solver that can be called from shell, and a plain CNF term
-- and run the CNF through the specified SAT solver
runPlain :: T.Text -> CNF Plain V -> IO ()
runPlain sat cnf = do
  let output = T.inproc sat [] (toLine cnf)
      res = T.grep (T.has "SATISFIABLE") output
  T.view res

-- | Take any plain CNF term and run it through the SAT solver
-- Run like: runMinisat $ toPlain [(3, True)] vEx1
runMinisat :: CNF Plain V -> IO ()
runMinisat = runPlain "minisat"
