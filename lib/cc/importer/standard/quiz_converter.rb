#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#
module CC::Importer::Standard
  module QuizConverter
    include CC::Importer

    def convert_quizzes
      quizzes = []
      questions = []
      
      conversion_dir = File.join(@unzipped_file_path, "temp_qti_conversions")

      resources_by_type("imsqti").each do |res|
        path = res[:href] || res[:files].first[:href]
        path = get_full_path(path)
        id = res[:migration_id]

        if File.exists?(path)
          qti_converted_dir = File.join(conversion_dir, id)
          if run_qti_converter(path, qti_converted_dir, id)
            # get quizzes/questions
            if q_list = convert_questions(qti_converted_dir, id)
              questions += q_list
            end
            if quiz = convert_assessment(qti_converted_dir, id)
              quizzes << quiz
            end
          end
        end
      end

      [{:assessment_questions => questions}, {:assessments => quizzes}]
    end
    
    def run_qti_converter(qti_file, out_folder, resource_id)
      # convert to 2.1
      command = Qti.get_conversion_command(out_folder, qti_file)
      logger.debug "Running migration command: #{command}"
      python_std_out = `#{command}`

      if $?.exitstatus == 0
        true
      else
        add_warning(I18n.t('lib.cc.standard.failed_to_convert_qti', 'Failed to import Assessment %{file_identifier}', :file_identifier => resource_id), "Output of QTI conversion tool: #{python_std_out.last(300)}")
        false
      end
    end

    def convert_questions(out_folder, resource_id)
      questions = nil
      begin
        manifest_file = File.join(out_folder, Qti::QtiExporter::MANIFEST_FILE)
        questions = Qti.convert_questions(manifest_file, :flavor => Qti::Flavors::COMMON_CARTRIDGE)
        prepend_id_to_questions(questions, resource_id)
      rescue
        add_warning(I18n.t('lib.cc.standard.failed_to_convert_qti', 'Failed to import Assessment %{file_identifier}', :file_identifier => resource_id), $!)
      end
      questions
    end

    def convert_assessment(out_folder, resource_id)
      quiz = nil
      begin
        manifest_file = File.join(out_folder, Qti::QtiExporter::MANIFEST_FILE)
        quizzes = Qti.convert_assessments(manifest_file, :flavor => Qti::Flavors::COMMON_CARTRIDGE)
        prepend_id_to_assessments(quizzes, resource_id)
        if quiz = quizzes.first
          quiz[:migration_id] = resource_id
        end
      rescue
         add_warning(I18n.t('lib.cc.standard.failed_to_convert_qti', 'Failed to import Assessment %{file_identifier}', :file_identifier => resource_id), $!)
      end
      quiz
    end
    
  end
end