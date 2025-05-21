#!/usr/bin/python

# Copyright 2024-2025 NetCracker Technology Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import json


def list_instances(folder):
    with open(folder + '/snapshot.json') as f:
        config = json.load(f)

    for topic in config['topics']:
        print(topic['name'])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('folder')
    args = parser.parse_args()
    list_instances(args.folder)
