require 'spec_helper'
require_relative '../app'

describe Status do
  describe '::new_unhealth_status' do
    subject { described_class.new_unhealth_status }
    it 'is unhealth' do
      expect(subject.status).to eq(described_class::UNHEALTH)
    end
  end
  describe '::new_health_status' do
    subject { described_class.new_health_status }
    it 'is health' do
      expect(subject.status).to eq(described_class::HEALTH)
    end
  end
end
