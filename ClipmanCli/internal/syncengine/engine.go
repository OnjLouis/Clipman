package syncengine

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
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
	retries := e.Retries
	if retries <= 0 {
		retries = 3
	}
	var last error
	mutationTime := time.Now().UnixMilli()
	for attempt := 0; attempt <= retries; attempt++ {
		state, err := e.Read(ctx)
		if err != nil {
			return nil, err
		}
		merge.Normalize(&state.Database, mutationTime)
		changed, result, err := mutation(&state.Database, mutationTime)
		if err != nil {
			return nil, err
		}
		if !changed {
			return result, nil
		}
		merge.Normalize(&state.Database, mutationTime)
		encoded, err := clipdb.Encode(state.Database, e.Password, state.Blob)
		if err != nil {
			return nil, err
		}
		_, err = e.Client.Put(ctx, encoded, state.Revision, !state.Exists)
		if err == nil {
			return result, nil
		}
		if !errors.Is(err, server.ErrConflict) {
			return nil, err
		}
		last = err
		time.Sleep(time.Duration(30+attempt*40) * time.Millisecond)
	}
	return nil, fmt.Errorf("database changed repeatedly; operation was not committed: %w", last)
}
