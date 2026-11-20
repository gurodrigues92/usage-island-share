import importlib.util
import json
import os
import time
from pathlib import Path
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone, timedelta

SOURCE = Path(__file__).resolve().parents[1] / 'Sources/UsageIsland/Resources/usage-analytics.py'
spec = importlib.util.spec_from_file_location('usage_analytics', SOURCE)
analytics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analytics)


class AnalyticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.db = self.home / 'cache/ledger.sqlite3'
        self.date = datetime.now(timezone.utc).isoformat()
        self.log = self.home / '.claude/projects/project/session.jsonl'
        self.log.parent.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def claude(self, request='r1', output=20, cached=30):
        return dict(timestamp=self.date, cwd=str(self.home / 'project'), requestId=request,
                    message=dict(id='m1', model='claude-sonnet-4-6', content='PRIVATE BODY MUST NOT BE STORED',
                                 usage=dict(input_tokens=10, output_tokens=output,
                                            cache_read_input_tokens=cached, cache_creation_input_tokens=5)))

    def append(self, row, file=None):
        with (file or self.log).open('a') as stream:
            stream.write(json.dumps(row) + '\n')

    def run_collector(self, budget=32*1024*1024):
        return analytics.run(self.home, self.db, budget)

    def test_dedup_streaming_and_persistence_after_source_deletion(self):
        self.append(self.claude(output=10)); self.append(self.claude(output=20))
        first = self.run_collector()
        self.assertEqual(first['rows'][0]['calls'], 1)
        self.assertEqual(first['rows'][0]['output'], 20)
        self.assertEqual(self.run_collector()['rows'], first['rows'])
        self.log.unlink()
        self.assertEqual(self.run_collector()['rows'], first['rows'])

    def test_missing_price_is_not_required_for_token_counting(self):
        row = self.claude(); row['message']['model'] = 'unknown-routed-model'
        self.append(row)
        self.assertEqual(self.run_collector()['rows'][0]['model'], 'unknown-routed-model')

    def test_cache_is_disjoint_and_body_never_reaches_ledger(self):
        self.append(self.claude())
        row = self.run_collector()['rows'][0]
        self.assertEqual((row['input'], row['output'], row['cacheRead'], row['cacheWrite']), (10,20,30,5))
        con = sqlite3.connect(self.db)
        text = str(con.execute('SELECT * FROM events').fetchall()) + str(con.execute('SELECT * FROM files').fetchall())
        con.close()
        self.assertNotIn('PRIVATE BODY', text)
        self.assertEqual(self.db.stat().st_mode & 0o777, 0o600)

    def test_codex_cached_input_is_not_counted_twice(self):
        file = self.home / '.codex/sessions/session.jsonl'; file.parent.mkdir(parents=True)
        self.append(dict(type='session_meta', timestamp=self.date, payload=dict(cwd=str(self.home/'repo'),model='gpt-fixture')), file)
        self.append(dict(type='token_usage_record', timestamp=self.date,
                         payload=dict(response_id='response-1',usage=dict(input_tokens=100,cached_input_tokens=80,output_tokens=10))), file)
        row = self.run_collector()['rows'][0]
        self.assertEqual((row['input'],row['cacheRead'],row['output']), (20,80,10))
        self.assertEqual(row['model'], 'gpt-fixture')

    def test_invalid_counter_does_not_become_zero_usage(self):
        row = self.claude(); row['message']['usage']['input_tokens'] = True
        self.append(row)
        self.assertEqual(self.run_collector()['rows'], [])

    def test_truncation_rescans_without_double_counting(self):
        self.append(self.claude(request='one')); self.run_collector()
        self.log.write_text('')
        self.append(self.claude(request='two'))
        self.assertEqual(self.run_collector()['rows'][0]['calls'], 2)

    def test_partial_last_line_is_read_after_it_is_completed(self):
        encoded = json.dumps(self.claude())
        self.log.write_text(encoded[:60])
        self.assertEqual(self.run_collector()['rows'], [])
        with self.log.open('a') as f: f.write(encoded[60:] + '\n')
        self.assertEqual(self.run_collector()['rows'][0]['calls'], 1)

    def test_byte_budget_resumes_and_keeps_previous_counts(self):
        for i in range(20): self.append(self.claude(request='request-' + str(i)))
        result = self.run_collector(budget=1200)
        self.assertTrue(result['incomplete'])
        for _ in range(30):
            result = self.run_collector(budget=1200)
            if not result['incomplete']: break
        self.assertFalse(result['incomplete'])
        self.assertEqual(result['rows'][0]['calls'],20)

    def test_fork_copy_is_deduplicated_by_request_identity(self):
        self.append(self.claude())
        sibling = self.log.parent / 'fork.jsonl'; sibling.write_bytes(self.log.read_bytes())
        self.assertEqual(self.run_collector()['rows'][0]['calls'],1)

    def test_oversized_record_does_not_hold_subsequent_records_forever(self):
        self.log.write_text(json.dumps({'content':'x' * (3*1024*1024)}) + '\n')
        self.append(self.claude())
        result = self.run_collector()
        self.assertEqual(result['rows'][0]['calls'],1)
        self.assertEqual(result['warnings'],[])
        self.assertFalse(result['incomplete'])

    def test_worktree_is_grouped_under_common_repository(self):
        main = self.home / 'main'; (main/'.git/worktrees/branch').mkdir(parents=True)
        branch = self.home / 'branch'; branch.mkdir()
        (branch/'.git').write_text('gitdir: ' + str(main/'.git/worktrees/branch'))
        (main/'.git/worktrees/branch/commondir').write_text('../..')
        self.assertEqual(analytics.project_name(str(branch)), 'main')

    def test_grok_real_log_counter_keys(self):
        file = self.home / '.grok/logs/unified.jsonl'; file.parent.mkdir(parents=True)
        self.append(dict(ts=self.date,msg='shell.turn.inference_done',ctx=dict(prompt_tokens=100,cached_prompt_tokens=90,completion_tokens=7)),file)
        row = self.run_collector()['rows'][0]
        self.assertEqual((row['provider'],row['input'],row['cacheRead'],row['output']),('SuperGrok',10,90,7))

    def test_legacy_codex_is_supported_without_repeated_cumulative_counts(self):
        file = self.home / '.codex/sessions/old.jsonl'; file.parent.mkdir(parents=True)
        usage = dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)
        row = dict(type='event_msg',timestamp=self.date,payload=dict(type='token_count',info=dict(total_token_usage=usage,last_token_usage=usage)))
        self.append(row,file); self.append(row,file)
        result = self.run_collector()['rows'][0]
        self.assertEqual((result['calls'],result['input'],result['cacheRead']),(1,20,80))

    def test_modern_and_legacy_events_in_same_file_are_not_added_together(self):
        file = self.home / '.codex/sessions/both.jsonl'; file.parent.mkdir(parents=True)
        usage = dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)
        self.append(dict(type='event_msg',timestamp=self.date,payload=dict(type='token_count',info=dict(total_token_usage=usage,last_token_usage=usage))),file)
        self.append(dict(type='token_usage_record',timestamp=self.date,payload=dict(response_id='r',usage=usage)),file)
        result = self.run_collector()['rows'][0]
        self.assertEqual((result['calls'],result['input']),(1,20))


    def test_full_365_day_window_includes_older_usage_for_all_local_sources(self):
        old=datetime.now(timezone.utc)-timedelta(days=180)
        row=self.claude();row['timestamp']=old.isoformat();self.append(row)
        opencode=self.home/'.local/share/opencode/opencode.db';opencode.parent.mkdir(parents=True)
        con=sqlite3.connect(opencode)
        con.execute('CREATE TABLE message(id TEXT,time_created INTEGER,data TEXT)')
        con.execute('INSERT INTO message VALUES(?,?,?)',('old',int(old.timestamp()*1000),json.dumps({'modelID':'fixture','tokens':{'input':10,'output':20}})))
        con.commit();con.close()
        rows=self.run_collector()['rows']
        self.assertEqual({r['provider'] for r in rows},{'Claude','OpenCode'})
        self.assertEqual({r['day'] for r in rows},{old.date().isoformat()})

    def test_discarded_tail_warning_persists_across_unchanged_refreshes(self):
        self.log.write_text('{"message":')
        os.utime(self.log,(time.time()-600,time.time()-600))
        first=self.run_collector();second=self.run_collector()
        self.assertIn('Há registros finais incompletos aguardando continuação',first['warnings'])
        self.assertEqual(second['warnings'],first['warnings'])
        self.assertFalse(second['incomplete'])

    def test_malformed_direct_record_does_not_remove_valid_legacy_counts(self):
        file=self.home/'.codex/sessions/session.jsonl';file.parent.mkdir(parents=True)
        usage=dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)
        self.append(dict(type='event_msg',timestamp=self.date,payload=dict(type='token_count',info=dict(total_token_usage=usage,last_token_usage=usage))),file)
        before=self.run_collector()['rows']
        self.append(dict(type='token_usage_record',timestamp=self.date,payload=dict(response_id='bad',usage=None)),file)
        self.assertEqual(self.run_collector()['rows'],before)
        self.assertEqual(self.run_collector()['rows'],before)

    def test_old_unvalidated_direct_marker_is_repaired_by_rescan(self):
        file=self.home/'.codex/sessions/session.jsonl';file.parent.mkdir(parents=True)
        usage=dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)
        self.append(dict(type='event_msg',timestamp=self.date,payload=dict(type='token_count',info=dict(total_token_usage=usage,last_token_usage=usage))),file)
        self.append(dict(type='token_usage_record',timestamp=self.date,payload=dict(response_id='bad',usage=None)),file)
        expected=self.run_collector()['rows']
        con=sqlite3.connect(self.db)
        raw=con.execute('SELECT meta FROM files WHERE path=?',(str(file),)).fetchone()[0]
        meta=json.loads(raw);meta['hasDirect']=True;meta.pop('directValidated',None)
        con.execute('UPDATE files SET meta=? WHERE path=?',(json.dumps(meta),str(file)))
        con.execute('DELETE FROM events');con.commit();con.close()
        self.assertEqual(self.run_collector()['rows'],expected)


    def test_large_usage_record_is_counted_and_private_body_never_persisted(self):
        row=self.claude();row['message']['content']='PRIVATE_STREAM_SENTINEL ' + '界\\"'*800000
        self.append(row)
        for _ in range(300):
            result=self.run_collector(budget=128*1024)
            con=sqlite3.connect(self.db)
            state=str(con.execute('SELECT meta FROM files').fetchall())
            con.close()
            self.assertNotIn('PRIVATE_STREAM_SENTINEL',state)
            self.assertNotIn('界',state)
            self.assertLess(len(state),20000)
            if not result['incomplete']: break
        self.assertFalse(result['incomplete'])
        self.assertEqual(result['rows'][0]['calls'],1)
        self.assertEqual(result['rows'][0]['input'],10)
        self.assertEqual(result['warnings'],[])
        self.assertEqual(result['progress']['bytesRead'],self.log.stat().st_size)

    def test_projection_handles_escapes_structures_and_every_byte_boundary(self):
        row=self.claude();row['cwd']='/work/ação-界';row['message']['content']=[{'text':'secret " \\ \n 界'},[True,False,None,1.2e-5,{'payload':{'usage':{'input_tokens':999}}}]]
        encoded=(json.dumps(row,ensure_ascii=False)+'\n').encode()
        for size in (1,7,23,64):
            parser=analytics.CounterJSONStream();rows=[];invalid=0
            for start in range(0,len(encoded),size):
                found,bad=parser.feed(encoded[start:start+size]);rows.extend(found);invalid+=bad
                parser=analytics.CounterJSONStream(json.loads(json.dumps(parser.state)))
            self.assertEqual(invalid,0)
            self.assertEqual(len(rows),1)
            self.assertEqual(rows[0]['message']['usage'],row['message']['usage'])
            self.assertEqual(rows[0]['cwd'],row['cwd'])
            self.assertNotIn('content',rows[0]['message'])

    def test_malformed_record_recovers_at_next_newline_and_reports_count(self):
        good=json.dumps(self.claude())
        for bad in ('{"content":"bad\\q"}', '{"content": [1,]}', '{"content": 01}', '{"content": truee}', '{"content": "unterminated', '{"content": 123e}', '{"content": '+('1'*150)+'x}'):
            self.log.write_text(bad+'\n'+good+'\n')
            result=self.run_collector()
            self.assertEqual(result['rows'][0]['calls'],1)
            self.assertEqual(result['progress']['recordsInvalid'],1)
            self.assertFalse(result['incomplete'])
            self.assertIn('Há registros JSON inválidos não contabilizados',result['warnings'])
            self.assertEqual(self.run_collector()['progress']['recordsInvalid'],1)

    def test_old_partial_tail_can_finish_later_without_permanent_backlog(self):
        encoded=json.dumps(self.claude())
        self.log.write_text(encoded[:-15]);os.utime(self.log,(time.time()-86400,time.time()-86400))
        result=self.run_collector(budget=1024)
        self.assertFalse(result['incomplete']);self.assertEqual(result['progress']['pendingTailFiles'],1)
        self.assertEqual(result['rows'],[])
        with self.log.open('a') as handle: handle.write(encoded[-15:])
        result=self.run_collector()
        self.assertEqual(result['rows'][0]['calls'],1)
        self.assertEqual(result['progress']['pendingTailFiles'],0)
        self.assertFalse(result['incomplete']);self.assertEqual(result['warnings'],[])

    def test_old_skipped_records_are_rescanned_once_without_double_counting(self):
        self.append(self.claude(request='small'));self.run_collector()
        row=self.claude(request='large');row['message']['content']='secret'*600000;self.append(row)
        con=sqlite3.connect(self.db)
        raw=con.execute('SELECT meta FROM files WHERE path=?',(str(self.log),)).fetchone()[0]
        meta=json.loads(raw);meta.pop('readerVersion');meta['skipped']=1
        con.execute('UPDATE files SET offset=?,meta=? WHERE path=?',(self.log.stat().st_size,json.dumps(meta),str(self.log)))
        con.commit();con.close()
        for _ in range(20):
            result=self.run_collector(budget=256*1024)
            if not result['incomplete']:break
        self.assertEqual(result['rows'][0]['calls'],2)
        self.assertFalse(result['incomplete']);self.assertEqual(result['warnings'],[])
        self.assertEqual(self.run_collector()['rows'],result['rows'])

    def test_scheduler_services_other_files_before_revisiting_huge_active_file(self):
        self.log.write_text(json.dumps({'content':'x'*10000})+'\n')
        small=self.log.parent/'small.jsonl';self.append(self.claude(),small)
        first=self.run_collector(budget=1024)
        self.assertTrue(first['incomplete']);self.assertEqual(first['rows'],[])
        second=self.run_collector(budget=1024)
        self.assertTrue(second['incomplete']);self.assertEqual(second['rows'][0]['calls'],1)
        self.assertGreater(second['progress']['bytesRead'],first['progress']['bytesRead'])

    def test_usage_before_large_body_is_not_committed_until_record_closes(self):
        row=self.claude();row['message']['content']='private'*500000
        encoded=json.dumps(row)
        self.log.write_text(encoded[:-2])
        result=self.run_collector()
        self.assertEqual(result['rows'],[]);self.assertEqual(result['progress']['pendingTailFiles'],1)
        with self.log.open('a') as handle:handle.write(encoded[-2:]+'\n')
        result=self.run_collector()
        self.assertEqual(result['rows'][0]['calls'],1);self.assertEqual(result['warnings'],[])

    def test_metadata_like_content_cannot_create_fake_usage(self):
        self.append({'content':{'timestamp':self.date,'message':self.claude()['message']}})
        result=self.run_collector()
        self.assertEqual(result['rows'],[]);self.assertEqual(result['warnings'],[])


    def test_partial_numeric_counter_is_resumed_before_delimiter(self):
        row=self.claude();row['message']['usage']['input_tokens']=12345
        encoded=json.dumps(row);cut=encoded.index('12345')+2
        self.log.write_text(encoded[:cut])
        result=self.run_collector();self.assertEqual(result['rows'],[])
        with self.log.open('a') as handle:handle.write(encoded[cut:]+'\n')
        result=self.run_collector()
        self.assertEqual(result['rows'][0]['input'],12345)
        self.assertEqual(result['warnings'],[])


if __name__ == '__main__': unittest.main()
