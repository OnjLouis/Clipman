package syncengine

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/server"
)

type Engine struct {
	Client   *server.Client
	Password string
	Limits   clipdb.Limits
	Retries  int
}
type State struct {
	Database model.Database
	Blob     []byte
	Revision string
	Exists   bool
}
type Mutation func(*model.Database, int64) (changed bool, result any, err error)

func (e *Engine) Read(ctx context.Context) (State, error) {
	download, err := e.Client.Get(ctx)
	if errors.Is(err, server.ErrNotFound) {
		return State{Database: model.NewDatabase(time.Now().UnixMilli())}, nil
	}
	if err != nil {
		return State{}, err
	}
	database, err := clipdb.Decode(download.Data, e.Password, e.Limits)
	if err != nil {
		return State{}, err
	}
	return State{Database: database, Blob: download.Data, Revision: download.Revision, Exists: true}, nil
}

func (e *Engine) Mutate(ctx context.Context, mutation Mutation) (any, error) {
	result, _, err := e.MutateState(ctx, mutation)
	return result, err
}

// MutateState returns the exact state committed by a successful mutation so
// callers do not need to download and decrypt the same database again.
func (e *Engine) MutateState(ctx context.Context, mutation Mutation) (any, State, error) {
	retries := e.Retries
	if retries <= 0 {
		retries = 3
	}
	var last error
	mutationTime := time.Now().UnixMilli()
	for attempt := 0; attempt <= retries; attempt++ {
		state, err := e.Read(ctx)
		if err != nil {
			return nil, State{}, err
		}
		merge.Normalize(&state.Database, mutationTime)
		changed, result, err := mutation(&state.Database, mutationTime)
		if err != nil {
			return nil, State{}, err
		}
		if !changed {
			return result, state, nil
		}
		merge.Normalize(&state.Database, mutationTime)
		encoded, err := clipdb.EncodeWithLimits(state.Database, e.Password, state.Blob, e.Limits)
		if err != nil {
			return nil, State{}, err
		}
		metadata, err := e.Client.Put(ctx, encoded, state.Revision, !state.Exists)
		if err == nil {
			return result, State{
				Database: state.Database,
				Blob:     encoded,
				Revision: metadata.Revision,
				Exists:   true,
			}, nil
		}
		if !errors.Is(err, server.ErrConflict) {
			return nil, State{}, err
		}
		last = err
		time.Sleep(time.Duration(30+attempt*40) * time.Millisecond)
	}
	return nil, State{}, fmt.Errorf("database changed repeatedly; operation was not committed: %w", last)
}
