module Hledger.Cli.Commands.Check.Ordereddates (
  journalCheckOrdereddates
)
where

import Hledger
import Hledger.Cli.CliOptions
import Text.Printf

journalCheckOrdereddates :: CliOpts -> Journal -> Either String ()
journalCheckOrdereddates CliOpts{rawopts_=rawopts,reportspec_=rspec} j = do
  let ropts = (rsOpts rspec){accountlistmode_=ALFlat}
  let ts = filter (rsQuery rspec `matchesTransaction`) $
           jtxns $ journalSelectingAmountFromOpts ropts j
  let unique = boolopt "--unique" rawopts
  let date = transactionDateFn ropts
  let compare a b =
        if unique
        then date a <  date b
        else date a <= date b
  case checkTransactions compare ts of
    FoldAcc{fa_previous=Nothing} -> return ()
    FoldAcc{fa_error=Nothing}    -> return ()
    FoldAcc{fa_error=Just error, fa_previous=Just previous} -> do
      let 
        uniquestr = if unique then " and/or not unique" else ""
        positionstr = showGenericSourcePos $ tsourcepos error
        txn1str = linesPrepend  "  "      $ showTransaction previous
        txn2str = linesPrepend2 "> " "  " $ showTransaction error
      Left $ printf "transaction date is out of order%s\nat %s:\n\n%s"
        uniquestr
        positionstr
        (txn1str ++ txn2str)

data FoldAcc a b = FoldAcc
 { fa_error    :: Maybe a
 , fa_previous :: Maybe b
 }

checkTransactions :: (Transaction -> Transaction -> Bool)
  -> [Transaction] -> FoldAcc Transaction Transaction
checkTransactions compare = foldWhile f FoldAcc{fa_error=Nothing, fa_previous=Nothing}
  where
    f current acc@FoldAcc{fa_previous=Nothing} = acc{fa_previous=Just current}
    f current acc@FoldAcc{fa_previous=Just previous} =
      if compare previous current
      then acc{fa_previous=Just current}
      else acc{fa_error=Just current}

foldWhile :: (a -> FoldAcc a b -> FoldAcc a b) -> FoldAcc a b -> [a] -> FoldAcc a b
foldWhile _ acc [] = acc
foldWhile fold acc (a:as) =
  case fold a acc of
   acc@FoldAcc{fa_error=Just _} -> acc
   acc -> foldWhile fold acc as