module Json where

import Data.SBV ( SatResult(..)
                , SMTResult(..)
                , ThmResult(..))
import Data.SBV.Internals (showModel)
import Data.Text
import Data.Aeson hiding (json)

import V (V(..))
import VProp.Types
import Opts
import Config

instance ToJSON SMTResult where
  toJSON (Unsatisfiable _) = object [("isSat" :: Text) .= ("Unsatisfiable" :: Text)]
  toJSON (Satisfiable conf model) =
    object [("model" :: Text) .= showModel conf model]
  toJSON (SatExtField conf model) =
    object [("extModel" :: Text) .= showModel conf model]
  toJSON (Unknown _ msg) = object [("Unknown Error" :: Text) .= msg]
  toJSON (ProofError _ msg) = object [("Prover Error" :: Text) .= msg]


instance ToJSON SatResult where toJSON (SatResult x) = toJSON x
instance ToJSON ThmResult where toJSON (ThmResult x) = toJSON x

instance (Show d, Show a, ToJSON a, ToJSON d) => ToJSON (V a d) where
  toJSON (Plain x) = toJSON x
  toJSON (VChc d l r) = object [ (pack (show d) :: Text) .=
                                 object [ ("L" :: Text) .= toJSON l
                                        , ("R" :: Text) .= toJSON r
                                        ]
                               ]

-- Just keeping this for reference on writing a manual instance if needed later
-- | VIExpr instances for FromJSON
-- Test With: decode "{\"type\":\"I\", \"value\": 1000}" :: Maybe NPrim
-- instance FromJSON NPrim where
--   parseJSON = withObject "num" $ \x -> do
--     type' <- x .: "type"
--     case type' of
--       "I" -> I <$> x .: "value"
--       "D" -> D <$> x .: "value"
--       _   -> fail ("unknown numeric type: " ++ type')


instance FromJSON N_N
instance FromJSON NPrim
instance FromJSON B_B
instance FromJSON NN_N
instance FromJSON BB_B
instance FromJSON NN_B
instance FromJSON RefN
instance FromJSON Opn
instance FromJSON Var
instance (FromJSON a) => FromJSON (Dim a)
instance (FromJSON d, FromJSON a) => FromJSON (VIExpr d a)
instance (FromJSON d, FromJSON a, FromJSON b) => FromJSON (VProp d a b)

instance ToJSON B_B
instance ToJSON NN_N
instance ToJSON N_N
instance ToJSON NPrim
instance ToJSON BB_B
instance ToJSON NN_B
instance ToJSON RefN
instance ToJSON Opn
instance (ToJSON a) => ToJSON (Dim a)
instance ToJSON Var

instance (ToJSON a, ToJSON d) => ToJSON (VIExpr d a)
instance (ToJSON d, ToJSON a, ToJSON b) => ToJSON (VProp d a b)

instance ToJSON Opts
instance FromJSON Opts

instance FromJSON Solver
instance ToJSON Solver
instance FromJSON Settings
instance ToJSON Settings

-- parseOpt :: Parser (Maybe Opt)
-- parseOpt = do
--   when

-- parseOpts :: Value -> Parser [Opts]
-- parseOpts = withArray "optimizations" $ \arr ->  mapM mvRght (toList arr)

-- instance FromJSON Opts where
--   parseJSON = withObject "optimizations" $ \o ->
--     asum [
--          ]
