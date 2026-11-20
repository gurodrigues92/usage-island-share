import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('history', Path(__file__).parents[1] / 'Sources/UsageIsland/Resources/session-history.py')
history = importlib.util.module_from_spec(spec); spec.loader.exec_module(history)


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name); self.path = self.home / '.codex/sessions/session.jsonl'; self.path.parent.mkdir(parents=True)
    def write(self, rows):
        self.path.write_text('\n'.join(json.dumps(dict(timestamp='2026-10-22T10:00:00Z', **r)) for r in rows)+'\n')
    def test_known_secrets_are_redacted_before_output(self):
        secrets = ['oc_'+'sk_'+'A'*40, 'sk-'+'B'*32, 'ghp_'+'C'*35, 'eyJabc.def.ghi']
        value = history.redact(' '.join(secrets) + ' API_KEY=supersecret password="hidden"')
        for secret in secrets + ['supersecret', 'hidden']: self.assertNotIn(secret, value)
        self.assertIn('ocultad', value)
    def test_reasoning_excluded_and_user_content_redacted(self):
        key='oc_'+'sk_'+'Z'*30
        self.write([{'type':'response_item','payload':{'type':'message','role':'assistant','channel':'analysis','content':[{'type':'output_text','text':'INTERNAL_REASONING'}]}},
                    {'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Meu token '+key}]}}])
        result=history.detail(self.path,self.home)
        self.assertEqual(len(result['events']),1)
        self.assertNotIn(key,json.dumps(result)); self.assertNotIn('INTERNAL_REASONING',json.dumps(result))
    def test_missing_results_are_not_success_and_exit_one_is_failure(self):
        self.write([{'type':'response_item','payload':{'type':'function_call','call_id':'a','name':'exec_command','arguments':'{"cmd":"npm test"}'}},
                    {'type':'response_item','payload':{'type':'function_call','call_id':'b','name':'exec_command','arguments':'{"cmd":"swift test"}'}},
                    {'type':'response_item','payload':{'type':'function_call_output','call_id':'b','output':'Process exited with code 1'}}])
        events=history.detail(self.path,self.home)['events']
        self.assertEqual([e['status'] for e in events],['pending','failed'])
        self.assertEqual(events[0]['kind'],'test')
    def test_configuration_envelopes_do_not_replace_the_actual_conversation(self):
        self.write([{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'# AGENTS.md instructions\n<INSTRUCTIONS>context</INSTRUCTIONS>'}]}},
                    {'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Melhorar Usage Island'}]}}])
        events=history.detail(self.path,self.home)['events']
        self.assertEqual(len(events),1);self.assertEqual(events[0]['text'],'Melhorar Usage Island')
    def test_test_success_requires_explicit_zero_and_all_exits(self):
        self.assertEqual(history.outcome('Script completed'), 'received')
        self.assertEqual(history.outcome('{"exit_code":0}'), 'success')
        self.assertEqual(history.outcome('{"exit_code":0} {"exit_code":1}'), 'failed')
    def test_cannot_read_auth_or_escape_through_symlink(self):
        secret=self.home/'auth.jsonl';secret.write_text('{}')
        with self.assertRaises(ValueError): history.detail(secret,self.home)
        linked=self.path.parent/'link.jsonl'; linked.symlink_to(secret)
        self.assertFalse(history.allowed(linked,self.home))
    def test_index_uses_project_metadata_and_ignores_malformed_records(self):
        self.write([{'type':'session_meta','payload':{'cwd':'/work/loja'}}, {'type':'response_item','payload':'malformed'},
                    {'type':'turn_context','payload':{'model':'test-model'}},
                    {'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Corrigir carrinho'}]}}])
        item=history.index(self.home)['sessions'][0]
        self.assertEqual(item['project'],'loja'); self.assertEqual(item['title'],'Corrigir carrinho')
        self.assertEqual(item['model'],'test-model')
    def test_claude_thinking_is_not_exposed_and_tool_errors_remain_errors(self):
        claude=self.home/'.claude/projects/a/session.jsonl';claude.parent.mkdir(parents=True)
        claude.write_text('\n'.join(json.dumps(r) for r in [
            {'type':'assistant','message':{'role':'assistant','content':[{'type':'thinking','thinking':'PRIVATE'}, {'type':'tool_use','id':'a','name':'Read','input':{'file_path':'a.swift'}}]}},
            {'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'a','is_error':True,'content':'Failed'}]}}]))
        events=history.detail(claude,self.home)['events']
        self.assertEqual(len(events),1);self.assertEqual(events[0]['status'],'failed');self.assertNotIn('PRIVATE',str(events))


    def test_distinct_tool_calls_with_same_time_and_command_keep_their_results(self):
        self.write([{'type':'response_item','payload':{'type':'function_call','call_id':call,'name':'exec_command','arguments':'{"cmd":"npm test"}'}}
                    for call in ('first','second')] + [
                    {'type':'response_item','payload':{'type':'function_call_output','call_id':'first','output':'Process exited with code 0'}},
                    {'type':'response_item','payload':{'type':'function_call_output','call_id':'second','output':'Process exited with code 1'}}])
        events=history.detail(self.path,self.home)['events']
        self.assertEqual(len(events),2)
        self.assertEqual([e['status'] for e in events],['success','failed'])
        self.assertNotEqual(events[0]['id'],events[1]['id'])

    def test_long_messages_with_same_display_prefix_are_not_deduplicated(self):
        self.write([{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'x'*3100+suffix}]}}
                    for suffix in ('first','second')])
        self.assertEqual(len(history.detail(self.path,self.home)['events']),2)

    def test_oversized_or_malformed_records_report_partial_coverage(self):
        self.write([{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'x'*(1100*1024)}]}},
                    {'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Visible'}]}}])
        result=history.detail(self.path,self.home)
        self.assertEqual(len(result['events']),1)
        self.assertTrue(result['limited'])
        self.path.write_text('{broken JSON}\n')
        self.assertTrue(history.detail(self.path,self.home)['limited'])

    def test_single_claude_record_cannot_exceed_600_event_cap(self):
        claude=self.home/'.claude/projects/a/session.jsonl';claude.parent.mkdir(parents=True)
        claude.write_text(json.dumps({'type':'assistant','message':{'role':'assistant','content':[
            {'type':'tool_use','id':str(i),'name':'Read','input':{'file_path':str(i)}} for i in range(1000)]}})+'\n')
        result=history.detail(claude,self.home)
        self.assertEqual(len(result['events']),600)
        self.assertTrue(result['limited'])


    def test_running_wrapper_is_not_finished_even_with_one_completed_child(self):
        self.assertEqual(history.outcome('Script running with cell ID 123\n{"exit_code":0}'),'received')
        self.assertEqual(history.outcome('Process running with session ID 456\n{"exit_code":0}'),'received')

    def test_multibyte_transcript_stays_below_process_output_limit(self):
        self.write([{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':str(i)+'界'*3000}]}}
                    for i in range(600)])
        result=history.detail(self.path,self.home)
        self.assertEqual(len(result['events']),600)
        self.assertTrue(result['limited'])
        self.assertTrue(all(len(e['text'].encode('utf-8')) <= 3000 for e in result['events']))
        self.assertLess(len(json.dumps(result,ensure_ascii=False).encode('utf-8')),4*1024*1024)


if __name__ == '__main__': unittest.main()
