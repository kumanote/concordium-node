{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

-- |This module defines types for blockchain parameters, including genesis data,
-- baker parameters and finalization parameters.
module Concordium.GlobalState.Parameters (
    module Concordium.GlobalState.Parameters,
    module Concordium.Types.Parameters,
    module Concordium.Genesis.Data,
    BakerInfo,
    MintDistribution (..),
    TransactionFeeDistribution (..),
    GASRewards (..),
) where

import Control.Monad hiding (fail)
import Control.Monad.Fail
import qualified Data.Aeson as AE
import Data.Aeson.Types (FromJSON (..), withObject, (.:))
import qualified Data.ByteString.Lazy as BSL
import Prelude hiding (fail)

import Concordium.Common.Version
import Concordium.Genesis.Data
import Concordium.Types
import Concordium.Types.Accounts
import Concordium.Types.AnonymityRevokers
import Concordium.Types.IdentityProviders
import Concordium.Types.Parameters
import Concordium.Types.Updates

readIdentityProviders :: BSL.ByteString -> Maybe IdentityProviders
readIdentityProviders bs = do
    v <- AE.decode bs
    -- We only support Version 0 at this point for testing. When we support more
    -- versions we'll have to decode in a dependent manner, first reading the
    -- version, and then decoding based on that.
    guard (vVersion v == 0)
    return (vValue v)

readAnonymityRevokers :: BSL.ByteString -> Maybe AnonymityRevokers
readAnonymityRevokers bs = do
    v <- AE.decode bs
    -- We only support Version 0 at this point for testing. When we support more
    -- versions we'll have to decode in a dependent manner, first reading the
    -- version, and then decoding based on that.
    guard (vVersion v == 0)
    return (vValue v)

eitherReadIdentityProviders :: BSL.ByteString -> Either String IdentityProviders
eitherReadIdentityProviders bs = do
    v <- AE.eitherDecode bs
    unless (vVersion v == 0) $ Left $ "Incorrect version: " ++ show (vVersion v)
    return (vValue v)

eitherReadAnonymityRevokers :: BSL.ByteString -> Either String AnonymityRevokers
eitherReadAnonymityRevokers bs = do
    v <- AE.eitherDecode bs
    unless (vVersion v == 0) $ Left $ "Incorrect version: " ++ show (vVersion v)
    return (vValue v)

getExactVersionedCryptographicParameters :: BSL.ByteString -> Maybe CryptographicParameters
getExactVersionedCryptographicParameters bs = do
    v <- AE.decode bs
    -- We only support Version 0 at this point for testing. When we support more
    -- versions we'll have to decode in a dependent manner, first reading the
    -- version, and then decoding based on that.
    guard (vVersion v == 0)
    return (vValue v)

-- |Implementation-defined parameters, such as block size. They are not
-- protocol-level parameters hence do not fit into 'GenesisParametersV2'.
data RuntimeParameters = RuntimeParameters
    { -- |Maximum block size produced by the baker (in bytes). Note that this only
      -- applies to the blocks produced by this baker, we will still accept blocks
      -- of arbitrary size from other bakers.
      rpBlockSize :: !Int,
      -- |Timeout of block construction, i.e. the maximum time (in milliseconds) it
      -- may take to construct a block. After this amount of time, we will stop
      -- processing transaction groups in `filterTransactions` in Scheduler.hs
      -- and mark the rest as unprocessed.
      rpBlockTimeout :: !Duration,
      -- |Threshold for how far into the future we accept blocks. Blocks with a slot
      -- time that exceeds our current time + this threshold are rejected and the p2p
      -- is told to not relay these blocks.  Setting this to 'maxBound' will disable the
      -- check.  Otherwise, the value should not be so large as to overflow when added
      -- to a timestamp within the operational life of the node.
      rpEarlyBlockThreshold :: !Duration,
      -- |Maximum number of milliseconds we can get behind before skipping to the current time
      -- when baking.
      rpMaxBakingDelay :: !Duration,
      -- |Number of insertions to be performed in the transaction table before running
      -- a purge to remove long living transactions that have not been executed for more
      -- than `rpTransactionsKeepAliveTime` seconds.
      rpInsertionsBeforeTransactionPurge :: !Int,
      -- |Number of seconds after receiving a transaction during which it is kept in the
      -- transaction table if a purge is executed.
      rpTransactionsKeepAliveTime :: !TransactionTime,
      -- |Number of seconds between automatic transaction table purging  runs.
      rpTransactionsPurgingDelay :: !Int,
      -- |The accounts cache size
      rpAccountsCacheSize :: !Int,
      -- |The modules cache size
      rpModulesCacheSize :: !Int
    }

-- |Default runtime parameters, block size = 10MB.
defaultRuntimeParameters :: RuntimeParameters
defaultRuntimeParameters =
    RuntimeParameters
        { rpBlockSize = 10 * 10 ^ (6 :: Int), -- 10MB
          rpBlockTimeout = 3_000, -- 3 seconds
          rpEarlyBlockThreshold = 30_000, -- 30 seconds
          rpMaxBakingDelay = 10_000, -- 10 seconds
          rpInsertionsBeforeTransactionPurge = 1_000,
          rpTransactionsKeepAliveTime = 5 * 60, -- 5 min
          rpTransactionsPurgingDelay = 3 * 60, -- 3 min
          rpAccountsCacheSize = 10_000,
          rpModulesCacheSize = 1_000
        }

instance FromJSON RuntimeParameters where
    parseJSON = withObject "RuntimeParameters" $ \v -> do
        rpBlockSize <- v .: "blockSize"
        rpBlockTimeout <- v .: "blockTimeout"
        rpEarlyBlockThreshold <- v .: "earlyBlockThreshold"
        rpMaxBakingDelay <- v .: "maxBakingDelay"
        rpInsertionsBeforeTransactionPurge <- v .: "insertionsBeforeTransactionPurge"
        rpTransactionsKeepAliveTime <- (fromIntegral :: Int -> TransactionTime) <$> v .: "transactionsKeepAliveTime"
        rpTransactionsPurgingDelay <- v .: "transactionsPurgingDelay"
        rpAccountsCacheSize <- v .: "accountsCacheSize"
        rpModulesCacheSize <- v .: "modulesCacheSize"
        when (rpBlockSize <= 0) $
            fail "Block size must be a positive integer."
        when (rpEarlyBlockThreshold <= 0) $
            fail "The early block threshold must be a positive integer"
        when (rpAccountsCacheSize <= 0) $
            fail "Account cache size must be a positive integer"
        return RuntimeParameters{..}

-- |Values of updates that are stored in update queues.
-- These are slightly different to the 'UpdatePayload' type,
-- specifically in that for the foundation account we store
-- the account index rather than the account address.
data UpdateValue (cpv :: ChainParametersVersion) where
    -- |Protocol updates.
    UVProtocol :: forall cpv. !ProtocolUpdate -> UpdateValue cpv
    -- |Updates to the election difficulty parameter.
    UVElectionDifficulty :: (IsSupported 'PTElectionDifficulty cpv ~ 'True) => !ElectionDifficulty -> UpdateValue cpv
    -- |Updates to the euro:energy exchange rate.
    UVEuroPerEnergy :: forall cpv. !ExchangeRate -> UpdateValue cpv
    -- |Updates to the GTU:euro exchange rate.
    UVMicroGTUPerEuro :: forall cpv. !ExchangeRate -> UpdateValue cpv
    -- |Updates to the foundation account.
    UVFoundationAccount :: forall cpv. !AccountIndex -> UpdateValue cpv
    -- |Updates to the mint distribution.
    UVMintDistribution :: forall cpv. !(MintDistribution (MintDistributionVersionFor cpv)) -> UpdateValue cpv
    -- |Updates to the transaction fee distribution.
    UVTransactionFeeDistribution :: forall cpv. !TransactionFeeDistribution -> UpdateValue cpv
    -- |Updates to the GAS rewards.
    UVGASRewards :: forall cpv. !(GASRewards (GasRewardsVersionFor cpv)) -> UpdateValue cpv
    -- |Updates to the pool parameters.
    UVPoolParameters :: forall cpv. !(PoolParameters cpv) -> UpdateValue cpv
    -- |Adds a new anonymity revoker
    UVAddAnonymityRevoker :: forall cpv. !ArInfo -> UpdateValue cpv
    -- |Adds a new identity provider
    UVAddIdentityProvider :: forall cpv. !IpInfo -> UpdateValue cpv
    -- |Updates to root keys.
    UVRootKeys :: forall cpv. !(HigherLevelKeys RootKeysKind) -> UpdateValue cpv
    -- |Updates to level 1 keys.
    UVLevel1Keys :: forall cpv. !(HigherLevelKeys Level1KeysKind) -> UpdateValue cpv
    -- |Updates to level 2 keys.
    UVLevel2Keys :: forall cpv. !(Authorizations (AuthorizationsVersionFor cpv)) -> UpdateValue cpv
    -- |Updates to cooldown parameters for chain parameter version 1.
    UVCooldownParameters :: (IsSupported 'PTCooldownParametersAccessStructure cpv ~ 'True) => !(CooldownParameters cpv) -> UpdateValue cpv
    -- |Updates to time parameters for chain parameters version 1.
    UVTimeParameters :: (IsSupported 'PTTimeParameters cpv ~ 'True) => !TimeParameters -> UpdateValue cpv
    -- |Updates to timeout parameters for chain parameters version 2.
    UVTimeoutParameters :: (IsSupported 'PTTimeoutParameters cpv ~ 'True) => !TimeoutParameters -> UpdateValue cpv
    -- |Updates to minimum block time for chain parameters version 2.
    UVMinBlockTime :: (IsSupported 'PTMinBlockTime cpv ~ 'True) => !Duration -> UpdateValue cpv
    -- |Updates to block energy limit for chain parameters version 2.
    UVBlockEnergyLimit :: (IsSupported 'PTBlockEnergyLimit cpv ~ 'True) => !Energy -> UpdateValue cpv
    -- |Updates to the finalization committee parameters for chain parameters version 2.
    UVFinalizationCommitteeParameters :: (IsSupported 'PTFinalizationCommitteeParameters cpv ~ 'True) => !FinalizationCommitteeParameters -> UpdateValue cpv

deriving instance Eq (UpdateValue cpv)
deriving instance Show (UpdateValue cpv)
