import copy
import unittest
from urllib.parse import parse_qs, urlsplit
import legacy_gh_publication as m


class Tests(unittest.TestCase):
    def setUp(self):
        self.repo = 'adaptgurus/one'
        self.head = 'layersentry/p1-rke2-provisioning'
        self.base = 'one-7.4'
        self.pr = {'number': 1, 'html_url': 'https://github.com/adaptgurus/one/pull/1',
                   'body': 'LayerSentry-Run: exact', 'state': 'open', 'merged_at': None,
                   'head': {'ref': self.head, 'sha': m.EXPECTED[self.repo], 'repo': {'full_name': self.repo}},
                   'base': {'ref': self.base, 'repo': {'full_name': self.repo}}}

    def n(self, data):
        return m.normalize_prs(data, self.repo, self.head, self.base)

    def test_real_rest_identity(self):
        r = self.n([self.pr])[0]
        self.assertEqual(r['headRefOid'], m.EXPECTED[self.repo])
        self.assertEqual(r['state'], 'OPEN')

    def test_empty(self):
        self.assertEqual(self.n([]), [])

    def test_closed_and_merged_not_open(self):
        self.pr['state'] = 'closed'
        self.assertEqual(self.n([self.pr])[0]['state'], 'CLOSED')
        self.pr['merged_at'] = '2026-09-11'
        self.assertEqual(self.n([self.pr])[0]['state'], 'MERGED')

    def test_foreign_repository_and_base(self):
        for side, field, val in [('head', 'ref', 'other'), ('base', 'ref', 'main'),
                                 ('head', 'repo', {'full_name': 'other/one'}), ('base', 'repo', None)]:
            with self.subTest(side=side, field=field):
                p = copy.deepcopy(self.pr)
                p[side][field] = val
                with self.assertRaises(ValueError):
                    self.n([p])

    def test_invalid_url_sha_and_number(self):
        for field, val in [('number', True), ('html_url', 'https://example.com/pull/1'),
                           ('state', 'unknown'), ('body', {})]:
            with self.subTest(field=field):
                p = copy.deepcopy(self.pr)
                p[field] = val
                with self.assertRaises(ValueError):
                    self.n([p])
        self.pr['head']['sha'] = 'bad'
        with self.assertRaises(ValueError):
            self.n([self.pr])

    def test_truncation_malformed_rejected(self):
        for value in [None, {}, ['bad'], [self.pr] * 100]:
            with self.subTest(value=type(value)):
                with self.assertRaises(ValueError):
                    self.n(value)

    def test_exact_legacy_request_uses_rest_not_json_field(self):
        args = ('pr', 'list', '--repo', self.repo, '--head', self.head,
                '--base', self.base, '--state', 'all', '--json', 'url,body,headRefOid,state')
        req = m.legacy_request(args)
        query = parse_qs(urlsplit(req[3]).query)
        self.assertEqual(query['head'], ['adaptgurus:' + self.head])
        self.assertEqual(query['base'], [self.base])
        self.assertNotIn('headRefOid', req[3])
        bad = list(args)
        bad[7] = 'master'
        with self.assertRaises(ValueError):
            m.legacy_request(tuple(bad))

    def test_other_native_commands_untouched(self):
        self.assertIsNone(m.legacy_request(('pr', 'create', '--repo', self.repo)))

    def test_unexpected_list_signature_fails(self):
        with self.assertRaises(ValueError):
            m.legacy_request(('pr', 'list'))

    def test_multiple_results_not_collapsed(self):
        self.assertEqual(len(self.n([self.pr, self.pr])), 2)


if __name__ == '__main__':
    unittest.main()
