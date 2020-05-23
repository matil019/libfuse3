{-| Based on `System.Fuse` in the package "HFuse-0.2.5.0".

Below is the @LICENSE@ of "HFuse":

Copyright (c) Jérémy Bobbio
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the University nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
-}
module System.Fuse3.Fuse where

import Control.Exception (Exception, bracket, bracket_, finally)
import Control.Monad (unless, void)
import Foreign (Ptr, alloca, allocaBytes, callocBytes, free, nullPtr, peek, poke, pokeByteOff, with, withArray, withMany)
import Foreign.C (CInt(CInt), CString, Errno, peekCString, withCString)
import GHC.IO.Handle (hDuplicateTo)
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode(ExitSuccess), exitFailure, exitWith)
import System.IO (IOMode(ReadMode, WriteMode), stderr, stdin, stdout, withFile)
import System.IO.Error (catchIOError, ioeGetErrorString)
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.Process (createSession, exitImmediately, forkProcess)
import System.Posix.Types (Fd(Fd))

import qualified System.Posix.Signals as Signals

#include <fuse.h>

data FuseOperations fh = FuseOperations () -- TODO

-- Allocates a fuse_args struct to hold the commandline arguments.
withFuseArgs :: String -> [String] -> (Ptr CFuseArgs -> IO b) -> IO b
withFuseArgs prog args f = do
  let allArgs = (prog:args)
      argc = length allArgs
  withMany withCString allArgs $ \cArgs ->
    withArray cArgs $ \pArgv ->
      -- TODO call FUSE_ARGS_INIT instead?
      allocaBytes (#size struct fuse_args) $ \fuseArgs -> do
        (#poke struct fuse_args, argc) fuseArgs argc
        (#poke struct fuse_args, argv) fuseArgs pArgv
        (#poke struct fuse_args, allocated) fuseArgs (0::CInt)
        f fuseArgs `finally` fuse_opt_free_args fuseArgs

withStructFuse
  :: Exception e
  => Ptr CFuseChan
  -> Ptr CFuseArgs
  -> FuseOperations fh
  -> (e -> IO Errno)
  -> (Ptr CStructFuse -> IO b)
  -> IO b
withStructFuse = _notyet

-- Calls @fuse_parse_cmdline@ to parse the part of the commandline arguments that
-- we care about. @fuse_parse_cmdline@ will modify the `CFuseArgs` struct passed in
-- to remove those arguments; the `CFuseArgs` struct containing remaining arguments
-- must be passed to @fuse_mount@/@fuse_new@.
--
-- The multithreaded runtime will be used regardless of the threading flag!
-- See the comment in @fuse_session_exit@ for why.
--
-- TODO the second part of tuple may be unused
fuseParseCommandLine :: Ptr CFuseArgs -> IO (Maybe (Maybe String, Bool, Bool))
fuseParseCommandLine pArgs =
  alloca $ \pMountPt ->
  alloca $ \pMultiThreaded ->
  alloca $ \pFG -> do
    -- TODO do we need to poke here?
    poke pMultiThreaded 0
    poke pFG 0
    retval <- fuse_parse_cmdline pArgs pMountPt pMultiThreaded pFG
    if retval == 0
      then do
        cMountPt <- peek pMountPt
        mountPt <- if cMountPt /= nullPtr
          then do
            a <- peekCString cMountPt
            -- TODO why free?
            free cMountPt
            pure $ Just a
          else pure Nothing
        multiThreaded <- peek pMultiThreaded
        foreground <- peek pFG
        pure $ Just (mountPt, multiThreaded == 1, foreground == 1)
      else pure Nothing

-- Haskell version of @daemon(2)@
--
-- Mimics @daemon()@'s use of @_exit()@ instead of @exit()@; we depend on this in
-- `fuseMainRealP, because otherwise we'll unmount the filesystem when the foreground process exits.
daemon :: IO a -> IO b
-- `exitImmediately` never returns. This `error` is only here to please the
-- typechecker.
-- It's a dirty hack, but I think the problem is in the posix package, not
-- making this @IO a@ instead of @IO ()@
daemon io = do
  _ <- forkProcess (d `catchIOError` const exitFailure)
  exitImmediately ExitSuccess
  error "This is unreachable code"
  where
  d = do
    _ <- createSession
    changeWorkingDirectory "/"
    -- need to open @/dev/null@ twice because `hDuplicateTo` can't dup a
    -- ReadWriteMode to a ReadMode handle
    withFile "/dev/null" WriteMode $ \devNullOut -> do
      hDuplicateTo devNullOut stdout
      hDuplicateTo devNullOut stderr
    withFile "/dev/null" ReadMode $ \devNullIn -> do
      hDuplicateTo devNullIn stdin
    _ <- io
    exitWith ExitSuccess

-- Installs signal handlers for the duration of the main loop.
withSignalHandlers :: IO () -> IO a -> IO a
withSignalHandlers exitHandler = bracket_ setHandlers resetHandlers
  where
  setHandlers = do
    let sigHandler = Signals.CatchOnce exitHandler
    void $ Signals.installHandler Signals.sigINT  sigHandler Nothing
    void $ Signals.installHandler Signals.sigHUP  sigHandler Nothing
    void $ Signals.installHandler Signals.sigTERM sigHandler Nothing
    void $ Signals.installHandler Signals.sigPIPE Signals.Ignore Nothing
  resetHandlers = do
    void $ Signals.installHandler Signals.sigINT  Signals.Default Nothing
    void $ Signals.installHandler Signals.sigHUP  Signals.Default Nothing
    void $ Signals.installHandler Signals.sigTERM Signals.Default Nothing
    void $ Signals.installHandler Signals.sigPIPE Signals.Default Nothing

-- TODO do we need `CFuseBuf`?
handleOnce :: Ptr CFuseSession -> Ptr CFuseBuf -> Ptr CFuseChan -> IO ()
handleOnce session buf chan = do
  size <- fuse_chan_bufsize chan
  allocaBytes (fromIntegral size) $ \ptr -> do
    #{poke struct fuse_buf, mem}  buf ptr
    #{poke struct fuse_buf, size} buf size
    with chan $ \chanP -> do
      fuse_session_receive_buf session buf chanP
      fuse_session_process_buf session buf =<< peek chanP

forAllChans
  :: Ptr CFuseSession
  -> (Ptr CFuseChan -> IO a -> IO a)
  -> IO a
  -> IO a
forAllChans session fun cont = go nullPtr
  where
  go cur = do
    new <- fuse_session_next_chan session cur
    if new == nullPtr
      then cont
      else fun new $ go new

-- TODO: Add an unregister function to run as well
runInline
  :: (Fd -> IO () -> IO b)
  -> (b -> IO ())
  -> (Either String () -> IO a) -- TODO change to (IO a)
  -> Ptr CStructFuse
  -> IO a
runInline register unregister act pFuse = bracket
  (callocBytes #{size struct fuse_buf}) free $ \buf -> do
    session <- fuse_get_session pFuse
    let registerChan chan cont = do
          fd <- fuse_chan_fd chan
          bracket
            (register fd (handleOnce session buf chan))
            unregister
            (const cont)
    ret <- forAllChans session registerChan $ withSignalHandlers (fuse_session_exit session) $ act $ Right ()
    fuse_session_exit session
    pure ret

-- Mounts the filesystem, forks, and then starts fuse
fuseMainReal
  :: Exception e
  => Maybe (Fd -> IO () -> IO b, b -> IO (), Either String () -> IO a)
  -> Bool
  -> FuseOperations fh
  -> (e -> IO Errno)
  -> Ptr CFuseArgs
  -> String
  -> IO a
fuseMainReal inline foreground ops handler pArgs mountPt =
  let strategy = case inline of
        Just (register, unregister, act) -> runInline register unregister act
        Nothing -> if foreground
          then (>>) (changeWorkingDirectory "/") . procMain
          else daemon . procMain
  in withCString mountPt $ \cMountPt -> bracket
       (fuse_mount cMountPt pArgs)
       (const $ fuse_unmount cMountPt nullPtr) $ \pFuseChan -> do
         if pFuseChan == nullPtr
           then case inline of
             Nothing -> exitFailure
             -- TODO: Add some way to notify the called application
             -- whether fuse is up, or not
             Just (_, _, act) -> act $ Left "Failed to create fuse handle"
           else withStructFuse pFuseChan pArgs ops handler strategy
  where
  -- here, we're finally inside the daemon process, we can run the main loop
  procMain pFuse = do
    session <- fuse_get_session pFuse
    -- calling fuse_session_exit to exit the main loop only appears to work
    -- with the multithreaded fuse loop. In the single-threaded case, FUSE
    -- depends on their recv() call to finish with EINTR when signals arrive.
    -- This doesn't happen with GHC's signal handling in place.
    withSignalHandlers (fuse_session_exit session) $ do
      retVal <- fuse_loop_mt pFuse
      if retVal == 1
        then exitWith ExitSuccess
        else exitFailure

fuseRun :: Exception e => String -> [String] -> FuseOperations fh -> (e -> IO Errno) -> IO ()
fuseRun prog args ops handler =
  catchIOError
    (withFuseArgs prog args $ \pArgs ->
       do cmd <- fuseParseCommandLine pArgs
          case cmd of
            Nothing -> fail ""
            Just (Nothing, _, _) -> fail "Usage error: mount point required"
            Just (Just mountPt, _, foreground) -> fuseMainReal Nothing foreground ops handler pArgs mountPt)
    ((\errStr -> unless (null errStr) (putStrLn errStr) >> exitFailure) . ioeGetErrorString)

-- | Main function of FUSE.
--
-- This is all that has to be called from the @main@ function. On top of
-- the `FuseOperations` record with filesystem implementation, you muset give
-- an exception handler converting Haskell exceptions to `Errno`.
--
-- This function does the following:
--
--   * parses command line options (@-d@, @-s@ and @-h@) ;
--
--   * passes all options after @--@ to the fusermount program ;
--
--   * mounts the filesystem by calling @fusermount@ ;
--
--   * installs signal handlers for `Signals.keyboardSignal`,
--     `Signals.lostConnection`,
--     `Signals.softwareTermination` and
--     `Signals.openEndedPipe` ;
--
--   * registers an exit handler to unmount the filesystem on program exit ;
--
--   * registers the operations ;
--
--   * calls FUSE event loop.
fuseMain :: Exception e => FuseOperations fh -> (e -> IO Errno) -> IO ()
fuseMain ops handler = do
  -- this used to be implemented using libfuse's fuse_main. Doing this will fork()
  -- from C behind the GHC runtime's back, which deadlocks in GHC 6.8.
  -- Instead, we reimplement fuse_main in Haskell using the forkProcess and the
  -- lower-level fuse_new/fuse_loop_mt API.
  prog <- getProgName
  args <- getArgs
  fuseRun prog args ops handler

-- TODO split module

-----------------------------------------------------------------------------
-- C land

---
-- exported C called from Haskell
---  

-- TODO check the type signatures against libfuse3

data CFuseArgs -- struct fuse_args

data CFuseChan -- struct fuse_chan

data CFuseSession -- struct fuse_session

data CStructFuse -- struct fuse

data CFuseBuf

foreign import ccall safe "fuse_mount"
  fuse_mount :: CString -> Ptr CFuseArgs -> IO (Ptr CFuseChan)

foreign import ccall safe "fuse_unmount"
  fuse_unmount :: CString -> Ptr CFuseChan -> IO ()

foreign import ccall unsafe "fuse_chan_bufsize"
  fuse_chan_bufsize :: Ptr CFuseChan -> IO Word -- TODO CWord?

foreign import ccall unsafe "fuse_chan_fd"
  fuse_chan_fd :: Ptr CFuseChan -> IO Fd

foreign import ccall safe "fuse_get_session"
  fuse_get_session :: Ptr CStructFuse -> IO (Ptr CFuseSession)

foreign import ccall safe "fuse_session_exit"
  fuse_session_exit :: Ptr CFuseSession -> IO ()

foreign import ccall safe "fuse_parse_cmdline"
  fuse_parse_cmdline :: Ptr CFuseArgs -> Ptr CString -> Ptr Int -> Ptr Int -> IO Int

foreign import ccall unsafe "fuse_session_next_chan"
  fuse_session_next_chan :: Ptr CFuseSession -> Ptr CFuseChan -> IO (Ptr CFuseChan)

foreign import ccall safe "fuse_opt_free_args"
  fuse_opt_free_args :: Ptr CFuseArgs -> IO ()

foreign import ccall safe "fuse_loop_mt"
  fuse_loop_mt :: Ptr CStructFuse -> IO Int

foreign import ccall unsafe "fuse_session_receive_buf"
  fuse_session_receive_buf :: Ptr CFuseSession -> Ptr CFuseBuf -> Ptr (Ptr CFuseChan) -> IO ()

foreign import ccall safe "fuse_session_receive_buf"
  fuse_session_process_buf :: Ptr CFuseSession -> Ptr CFuseBuf -> Ptr CFuseChan -> IO ()
